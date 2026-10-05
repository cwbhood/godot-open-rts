shader_type spatial;

// Desert ground: sand in several tones with wind ripples, cracked hardpan flats, gravel,
// vegetation patches, wet shores and layered sandstone. Biome weights come from vertex colors
// written by DesertMapGenerator.gd (r: vegetation, g: rock, b: wet ground, a: hardpan); height
// and slope shape dunes and rock, and a domain-warped, rotated noise stack keeps the two small
// noise textures from showing a repeating pattern at any zoom.

uniform vec3 sand_pale : source_color = vec3(0.86, 0.74, 0.57);
uniform vec3 sand_light : source_color = vec3(0.83, 0.66, 0.47);
uniform vec3 sand_dark : source_color = vec3(0.78, 0.59, 0.42);
uniform vec3 sand_red : source_color = vec3(0.76, 0.50, 0.34);
uniform vec3 hardpan_color : source_color = vec3(0.80, 0.72, 0.60);
uniform vec3 crack_color : source_color = vec3(0.45, 0.36, 0.28);
uniform vec3 gravel_color : source_color = vec3(0.50, 0.41, 0.34);
uniform vec3 rock_light : source_color = vec3(0.76, 0.50, 0.35);
uniform vec3 rock_dark : source_color = vec3(0.46, 0.29, 0.21);
uniform vec3 grass_light : source_color = vec3(0.55, 0.57, 0.28);
uniform vec3 grass_dark : source_color = vec3(0.29, 0.37, 0.18);
uniform vec3 wet_color : source_color = vec3(0.50, 0.40, 0.30);
uniform vec3 lakebed_tint : source_color = vec3(0.45, 0.55, 0.50);
uniform float ripple_strength = 0.35;
uniform float relief_strength = 0.45;
uniform float ripple_frequency = 5.0;
uniform float crack_scale = 0.75;
uniform vec2 wind_direction = vec2(0.8, 0.6);
uniform sampler2D noise_large : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_detail : hint_default_white, filter_linear_mipmap, repeat_enable;

varying vec3 world_position;
varying vec3 world_normal;

const mat2 ROTATE_A = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
const mat2 ROTATE_B = mat2(vec2(0.28, -0.96), vec2(0.96, 0.28));

float detail_height(vec2 p)
{
  return texture(noise_detail, p * 0.3).r * 0.6 + texture(noise_detail, ROTATE_A * p * 1.1).r * 0.4;
}

vec2 hash22(vec2 p)
{
  vec3 a = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
  a += dot(a, a.yzx + 33.33);
  return fract((a.xx + a.yz) * a.zy);
}

// distance to the nearest edge between Voronoi cells: dried-mud cracks
float crack_distance(vec2 p)
{
  vec2 cell = floor(p);
  vec2 local = fract(p);
  vec2 nearest_offset = vec2(0.0);
  vec2 nearest = vec2(0.0);
  float best = 8.0;
  for (int j = -1; j <= 1; j++)
  {
    for (int i = -1; i <= 1; i++)
    {
      vec2 offset = vec2(float(i), float(j));
      vec2 r = offset + hash22(cell + offset) - local;
      float d = dot(r, r);
      if (d < best)
      {
        best = d;
        nearest = r;
        nearest_offset = offset;
      }
    }
  }
  best = 8.0;
  for (int j = -1; j <= 1; j++)
  {
    for (int i = -1; i <= 1; i++)
    {
      vec2 offset = nearest_offset + vec2(float(i), float(j));
      vec2 r = offset + hash22(cell + offset) - local;
      if (dot(nearest - r, nearest - r) > 0.0001)
      {
        best = min(best, dot(0.5 * (nearest + r), normalize(r - nearest)));
      }
    }
  }
  return best;
}

void vertex()
{
  world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
  world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment()
{
  vec2 p = world_position.xz;
  // world size of one pixel: fades out detail that would only shimmer when zoomed out
  float pixel = length(fwidth(p));
  // domain warp so that no texture repeat lines up into a grid
  vec2 warp = vec2(texture(noise_large, p * 0.0031).r, texture(noise_large, ROTATE_B * p * 0.0029).r);
  vec2 pw = p + (warp - 0.5) * 9.0;
  float n_macro = texture(noise_large, ROTATE_A * pw * 0.0042).r;
  float n_large = texture(noise_large, pw * 0.011).r;
  float n_mid = texture(noise_large, ROTATE_B * pw * 0.041 + vec2(0.31, 0.77)).r;
  float n_detail = detail_height(p);

  // sand: pale, golden and red-ochre fields over hundreds of metres, softer variation inside
  float field = smoothstep(0.3, 0.7, n_macro);
  vec3 sand_base = mix(mix(sand_light, sand_pale, smoothstep(0.35, 0.75, n_large)), sand_red,
      smoothstep(0.62, 0.9, n_macro + (n_large - 0.5) * 0.3) * 0.75);
  vec3 sand = mix(sand_dark, sand_base, smoothstep(0.15, 0.75, n_large * 0.55 + n_mid * 0.25 + field * 0.2));
  sand *= 0.97 + 0.06 * n_detail;

  // dunes: crests lighter and finer, troughs a little darker and coarser
  float crest = smoothstep(0.4, 3.2, world_position.y) * (1.0 - smoothstep(0.3, 0.6, 1.0 - world_normal.y));
  sand = mix(sand, sand_pale * 1.03, crest * 0.35);

  // gravel and pebbles scattered in patches, most visible close up
  float gravel_patch = smoothstep(0.62, 0.78, texture(noise_large, ROTATE_A * pw * 0.023 + vec2(0.5)).r);
  float pebbles = smoothstep(0.66, 0.74, texture(noise_detail, ROTATE_B * p * 2.7).r);
  float gravel_w = gravel_patch * mix(0.25, 0.65, pebbles) * (1.0 - smoothstep(0.08, 0.3, pixel) * 0.5);
  sand = mix(sand, gravel_color * (0.85 + 0.3 * n_detail), gravel_w);

  // hardpan: pale clay broken into polygons by dark cracks
  float hardpan_w = smoothstep(0.2, 0.8, COLOR.a + (n_detail - 0.5) * 0.3);
  vec3 hardpan = hardpan_color * (0.93 + 0.12 * texture(noise_detail, p * 2.3).r);
  float crack_w = 0.0;
  if (hardpan_w > 0.01)
  {
    vec2 cp = (p + (vec2(n_detail, n_mid) - 0.5) * 0.5) * crack_scale;
    float edge = crack_distance(cp);
    float width = 0.025 + 0.015 * n_mid;
    // anti-aliased line that fades into a slight darkening when zoomed out
    float aa = pixel * crack_scale * 1.5;
    crack_w = (1.0 - smoothstep(width, width + aa, edge)) * (1.0 - smoothstep(0.12, 0.35, pixel));
    // coarser cracks between the big plates
    float big = crack_distance(cp * 0.31 + vec2(17.0));
    crack_w = max(crack_w, (1.0 - smoothstep(0.012, 0.012 + aa * 0.31, big)) * (1.0 - smoothstep(0.3, 0.8, pixel)));
    hardpan = mix(hardpan, hardpan * 0.94, smoothstep(0.2, 0.6, pixel));
    // plates curl slightly: lighter centres
    hardpan *= 0.96 + 0.06 * smoothstep(0.0, 0.3, edge);
  }
  vec3 color = mix(sand, mix(hardpan, crack_color, crack_w * 0.6), hardpan_w);

  // vegetation, broken up so it never forms clean circles
  float vegetation_w =
      smoothstep(0.35, 0.7, COLOR.r + (n_mid - 0.5) * 0.6 + (n_detail - 0.5) * 0.35);
  vec3 grass = mix(grass_dark, grass_light, smoothstep(0.2, 0.8, n_detail));
  float wet_w = smoothstep(0.1, 0.9, COLOR.b + (n_detail - 0.5) * 0.2);
  color = mix(color, wet_color * (0.92 + 0.16 * n_detail), wet_w);
  color = mix(color, grass, vegetation_w * (1.0 - wet_w * 0.6));

  // sandstone with horizontal strata and dark desert varnish in the cracks
  float slope = 1.0 - world_normal.y;
  float rock_w = clamp(COLOR.g + smoothstep(0.4, 0.65, slope), 0.0, 1.0);
  rock_w = smoothstep(0.35, 0.65, rock_w + (n_detail - 0.5) * 0.45);
  float strata = 0.5 + 0.5 * sin(world_position.y * 2.6 + n_mid * 3.0);
  float bands = 0.5 + 0.5 * sin(world_position.y * 0.9 + n_large * 2.0);
  vec3 rock = mix(rock_dark, rock_light, strata * 0.55 + n_detail * 0.3 + bands * 0.15);
  rock = mix(rock, rock * vec3(0.72, 0.68, 0.66), smoothstep(0.55, 0.8, n_detail) * 0.5);
  color = mix(color, rock, rock_w);

  // lake beds darken and turn greenish with depth
  float submerged = smoothstep(-0.2, -1.4, world_position.y);
  color = mix(color, color * lakebed_tint, submerged);

  ALBEDO = color;
  ROUGHNESS = mix(0.95, 0.55, wet_w);
  SPECULAR = 0.3;

  // normal perturbation: wind ripples on open sand plus grainy detail everywhere
  vec2 wind = normalize(wind_direction);
  float ripple_warp = n_mid * 6.0 + n_large * 4.0;
  float phase = dot(p, wind) * ripple_frequency + ripple_warp;
  float ripple_fade = 1.0 - smoothstep(0.08, 0.3, pixel * ripple_frequency);
  float ripple_w = ripple_strength * ripple_fade * (1.0 - max(rock_w, vegetation_w)) *
      (1.0 - hardpan_w * 0.9) * (1.0 - wet_w) * (1.0 - gravel_w);
  // sharper lee faces than stoss faces, like real ripples
  float ripple_shape = cos(phase) + 0.35 * cos(phase * 2.0 + 0.6);
  vec2 slope_xz = wind * ripple_shape * ripple_w;
  float e = 0.15;
  float hx = detail_height(p + vec2(e, 0.0)) - n_detail;
  float hz = detail_height(p + vec2(0.0, e)) - n_detail;
  slope_xz += vec2(hx, hz) / e * mix(0.06, 0.2, rock_w) * (1.0 - smoothstep(0.15, 0.5, pixel) * 0.6);
  // fake low dunes on the flat playable ground: shading only, the surface stays level
  float le = 2.0;
  float relief = texture(noise_large, pw * 0.014).r;
  float relief_x = texture(noise_large, (pw + vec2(le, 0.0)) * 0.014).r - relief;
  float relief_z = texture(noise_large, (pw + vec2(0.0, le)) * 0.014).r - relief;
  slope_xz += vec2(relief_x, relief_z) / le * relief_strength * world_normal.y * (1.0 - rock_w);
  // crack edges catch a little light
  slope_xz += vec2(n_detail - 0.5) * crack_w * hardpan_w * 0.3;
  vec3 perturbed = normalize(world_normal + vec3(-slope_xz.x, 0.0, -slope_xz.y));
  NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
}

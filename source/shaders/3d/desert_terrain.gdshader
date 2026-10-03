shader_type spatial;

// Desert ground: sand with wind ripples, hardpan flats, vegetation patches, wet shores and
// layered sandstone. Biome weights come from vertex colors written by DesertMapGenerator.gd
// (r: vegetation, g: rock, b: wet ground, a: hardpan).

uniform vec3 sand_light : source_color = vec3(0.91, 0.76, 0.55);
uniform vec3 sand_dark : source_color = vec3(0.80, 0.60, 0.40);
uniform vec3 hardpan_color : source_color = vec3(0.87, 0.77, 0.63);
uniform vec3 rock_light : source_color = vec3(0.74, 0.47, 0.32);
uniform vec3 rock_dark : source_color = vec3(0.47, 0.28, 0.20);
uniform vec3 grass_light : source_color = vec3(0.56, 0.57, 0.27);
uniform vec3 grass_dark : source_color = vec3(0.30, 0.37, 0.17);
uniform vec3 wet_color : source_color = vec3(0.50, 0.39, 0.28);
uniform vec3 lakebed_tint : source_color = vec3(0.45, 0.55, 0.50);
uniform float ripple_strength = 0.7;
uniform float relief_strength = 0.9;
uniform float ripple_frequency = 3.0;
uniform vec2 wind_direction = vec2(0.8, 0.6);
uniform sampler2D noise_large : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_detail : hint_default_white, filter_linear_mipmap, repeat_enable;

varying vec3 world_position;
varying vec3 world_normal;

float detail_height(vec2 p)
{
  return texture(noise_detail, p * 0.3).r * 0.6 + texture(noise_detail, p * 1.1).r * 0.4;
}

void vertex()
{
  world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
  world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment()
{
  vec2 p = world_position.xz;
  float n_large = texture(noise_large, p * 0.011).r;
  float n_mid = texture(noise_large, p * 0.047 + vec2(0.31, 0.77)).r;
  float n_detail = detail_height(p);

  // sand: large soft color variation plus fine grain
  vec3 sand = mix(sand_dark, sand_light, smoothstep(0.3, 0.7, n_large * 0.65 + n_mid * 0.35));
  sand *= 0.96 + 0.08 * n_detail;

  // hardpan: pale, flatter, speckled
  vec3 hardpan = hardpan_color * (0.94 + 0.12 * texture(noise_detail, p * 2.3).r);
  float hardpan_w = smoothstep(0.2, 0.8, COLOR.a + (n_detail - 0.5) * 0.3);
  vec3 color = mix(sand, hardpan, hardpan_w);

  // vegetation, broken up so it never forms clean circles
  float vegetation_w = smoothstep(0.35, 0.7, COLOR.r + (n_mid - 0.5) * 0.6 + (n_detail - 0.5) * 0.35);
  vec3 grass = mix(grass_dark, grass_light, smoothstep(0.2, 0.8, n_detail));
  float wet_w = smoothstep(0.1, 0.9, COLOR.b + (n_detail - 0.5) * 0.2);
  color = mix(color, wet_color * (0.92 + 0.16 * n_detail), wet_w);
  color = mix(color, grass, vegetation_w * (1.0 - wet_w * 0.6));

  // sandstone with horizontal strata
  float slope = 1.0 - world_normal.y;
  float rock_w = clamp(COLOR.g + smoothstep(0.4, 0.65, slope), 0.0, 1.0);
  rock_w = smoothstep(0.35, 0.65, rock_w + (n_detail - 0.5) * 0.45);
  float strata = 0.5 + 0.5 * sin(world_position.y * 2.6 + n_mid * 3.0);
  vec3 rock = mix(rock_dark, rock_light, strata * 0.65 + n_detail * 0.35);
  color = mix(color, rock, rock_w);

  // lake beds darken and turn greenish with depth
  float submerged = smoothstep(-0.2, -1.4, world_position.y);
  color = mix(color, color * lakebed_tint, submerged);

  ALBEDO = color;
  ROUGHNESS = mix(0.95, 0.55, wet_w);
  SPECULAR = 0.3;

  // normal perturbation: wind ripples on open sand plus grainy detail everywhere
  vec2 wind = normalize(wind_direction);
  float warp = n_mid * 7.0 + n_large * 4.0;
  float phase = dot(p, wind) * ripple_frequency + warp;
  float ripple_fade = 1.0 - clamp(length(fwidth(p)) * ripple_frequency * 0.6, 0.0, 1.0);
  float ripple_w = ripple_strength * ripple_fade * (1.0 - max(rock_w, vegetation_w)) *
                   (1.0 - hardpan_w * 0.8) * (1.0 - wet_w);
  vec2 slope_xz = wind * cos(phase) * ripple_w;
  float e = 0.15;
  float hx = detail_height(p + vec2(e, 0.0)) - n_detail;
  float hz = detail_height(p + vec2(0.0, e)) - n_detail;
  slope_xz += vec2(hx, hz) / e * mix(0.08, 0.2, rock_w);
  // fake low dunes on the flat playable ground: shading only, the surface stays level
  float le = 1.5;
  float relief = texture(noise_large, p * 0.018).r;
  float relief_x = texture(noise_large, (p + vec2(le, 0.0)) * 0.018).r - relief;
  float relief_z = texture(noise_large, (p + vec2(0.0, le)) * 0.018).r - relief;
  slope_xz += vec2(relief_x, relief_z) / le * relief_strength * world_normal.y * (1.0 - rock_w);
  vec3 perturbed = normalize(world_normal + vec3(-slope_xz.x, 0.0, -slope_xz.y));
  NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
}

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

// Supply route surface drawn on a flat ribbon. UV.x runs along the route in metres, UV.y
// goes across it from 0 to 1. 'kind' picks the look: 0 dirt track, 1 paved road, 2 railway.

uniform int kind = 0;
uniform vec3 dirt_color : source_color = vec3(0.6, 0.46, 0.33);
uniform vec3 asphalt_color : source_color = vec3(0.27, 0.27, 0.28);
uniform vec3 line_color : source_color = vec3(0.92, 0.88, 0.75);
uniform vec3 ballast_color : source_color = vec3(0.45, 0.42, 0.4);
uniform vec3 sleeper_color : source_color = vec3(0.3, 0.21, 0.14);
uniform vec3 rail_color : source_color = vec3(0.72, 0.72, 0.74);
instance uniform float road_length = 10.0;

float hash(vec2 p)
{
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p)
{
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
      mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
      mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
      u.y);
}

void fragment()
{
  float along = UV.x;
  float across = abs(UV.y - 0.5) * 2.0; // 0 in the middle, 1 at the edge
  float ends = min(along, road_length - along);
  vec3 color;
  float alpha;
  float roughness = 0.95;
  float metallic = 0.0;
  if (kind == 0)
  {
    float n = noise(vec2(along * 1.4, UV.y * 5.0));
    float ruts = smoothstep(0.14, 0.0, abs(across - 0.45));
    color = dirt_color * (0.88 + 0.24 * n) * (1.0 - 0.2 * ruts);
    alpha = smoothstep(1.0, 0.55 - 0.25 * n, across) * smoothstep(0.0, 1.5, ends) * 0.9;
  }
  else if (kind == 1)
  {
    float n = noise(vec2(along * 5.0, UV.y * 10.0));
    color = asphalt_color * (0.9 + 0.18 * n);
    float edge_line = smoothstep(0.8, 0.83, across) * smoothstep(0.92, 0.89, across);
    float centre_dash = step(0.5, fract(along / 2.4)) * smoothstep(0.06, 0.03, across);
    color = mix(color, line_color, max(edge_line * 0.75, centre_dash * 0.9));
    alpha = smoothstep(1.0, 0.95, across) * smoothstep(0.0, 0.4, ends);
    roughness = 0.85;
  }
  else
  {
    float n = noise(vec2(along * 9.0, UV.y * 18.0));
    color = ballast_color * (0.75 + 0.4 * n);
    float sleeper = step(fract(along / 0.55), 0.38) * step(across, 0.78);
    color = mix(color, sleeper_color * (0.85 + 0.3 * n), sleeper);
    float rail = smoothstep(0.07, 0.035, abs(across - 0.5));
    color = mix(color, rail_color, rail);
    metallic = rail * 0.8;
    roughness = mix(0.95, 0.35, rail);
    alpha = smoothstep(1.0, 0.9, across) * smoothstep(0.0, 0.4, ends);
  }
  ALBEDO = color;
  ALPHA = alpha;
  ROUGHNESS = roughness;
  METALLIC = metallic;
}

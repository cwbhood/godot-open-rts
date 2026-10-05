shader_type spatial;
render_mode blend_mix, cull_back, specular_schlick_ggx;

// Oasis water: depth-tinted, with shoreline foam and two scrolling normal layers.

uniform vec3 shallow_color : source_color = vec3(0.30, 0.66, 0.62);
uniform vec3 deep_color : source_color = vec3(0.05, 0.25, 0.33);
uniform vec3 foam_color : source_color = vec3(0.95, 0.93, 0.85);
uniform float depth_for_deep = 1.1;
uniform float foam_width = 0.12;
uniform vec2 flow = vec2(0.02, 0.012);
uniform sampler2D wave_normals : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

#include "res://source/shaders/3d/depth_reconstruction.gdshaderinc"

varying vec3 world_position;

void vertex()
{
  world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment()
{
  float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
  vec3 ground_world = depth_to_world(SCREEN_UV, depth, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
  float water_depth = max(world_position.y - ground_world.y, 0.0);

  float deep_w = smoothstep(0.0, depth_for_deep, water_depth);
  vec3 color = mix(shallow_color, deep_color, deep_w);

  vec2 p = world_position.xz;
  float foam_n = texture(foam_noise, p * 0.4 + TIME * flow * 2.0).r;
  float foam = 1.0 - smoothstep(0.0, foam_width * (0.6 + foam_n), water_depth);
  color = mix(color, foam_color, foam * 0.85);

  ALBEDO = color;
  ALPHA = clamp(mix(0.55, 0.93, deep_w) + foam, 0.0, 1.0);
  ROUGHNESS = 0.06;
  SPECULAR = 0.6;
  vec3 n1 = texture(wave_normals, p * 0.18 + TIME * flow).rgb;
  vec3 n2 = texture(wave_normals, p * 0.11 - TIME * flow.yx * 1.3).rgb;
  NORMAL_MAP = normalize(mix(n1, n2, 0.5));
  NORMAL_MAP_DEPTH = 0.45;
}

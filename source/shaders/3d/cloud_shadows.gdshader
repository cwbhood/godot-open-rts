shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, depth_test_disabled, cull_disabled;

// Full-screen pass that darkens whatever is under a cloud, seen along the sun direction.
// Like the fog of war overlay it rebuilds each pixel's world position from the depth buffer,
// so terrain, props, units and buildings all receive the same moving shadows.

uniform sampler2D cloud_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture;
uniform float period = 400.0;
uniform vec2 offset = vec2(0.0);
uniform float coverage = 0.4;
uniform float softness = 0.22;
uniform float opacity = 0.5;
uniform float cloud_height = 32.0;
uniform vec3 sun_direction = vec3(0.3, -0.8, 0.3);
uniform vec3 shadow_tint : source_color = vec3(0.42, 0.47, 0.6);

void vertex()
{
  POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment()
{
  float depth = textureLod(depth_texture, SCREEN_UV, 0.0).x;
  vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
  view.xyz /= view.w;
  vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;

  // walk from the surface towards the sun up to the cloud layer
  vec3 to_sun = -normalize(sun_direction);
  vec3 cloud_point = world + to_sun * max(cloud_height - world.y, 0.0) / max(to_sun.y, 0.1);
  vec2 uv = (cloud_point.xz - offset) / period;
  float value = texture(cloud_texture, uv).r * 0.82 +
      texture(cloud_texture, uv * 4.3 + vec2(0.37, 0.11)).r * 0.18;
  float threshold = 1.0 - coverage;
  float shadow = smoothstep(threshold - softness * 0.5, threshold + softness, value) * opacity;
  ALBEDO = mix(vec3(1.0), shadow_tint, shadow);
}

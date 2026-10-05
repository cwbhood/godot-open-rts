shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled;

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
// shade color blended over the ground. A plain alpha blend instead of a multiply: the
// Compatibility renderer tonemaps unshaded output, so multiplying by 'white' still darkened
// the whole screen there.
uniform vec3 shadow_tint : source_color = vec3(0.10, 0.12, 0.2);

#include "res://source/shaders/3d/depth_reconstruction.gdshaderinc"

void vertex()
{
  POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment()
{
  float depth = textureLod(depth_texture, SCREEN_UV, 0.0).x;
  vec3 world = depth_to_world(SCREEN_UV, depth, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);

  // walk from the surface towards the sun up to the cloud layer
  vec3 to_sun = -normalize(sun_direction);
  vec3 cloud_point = world + to_sun * max(cloud_height - world.y, 0.0) / max(to_sun.y, 0.1);
  vec2 uv = (cloud_point.xz - offset) / period;
  float value = texture(cloud_texture, uv).r * 0.82 +
      texture(cloud_texture, uv * 4.3 + vec2(0.37, 0.11)).r * 0.18;
  float threshold = 1.0 - coverage;
  float shadow = smoothstep(threshold - softness * 0.5, threshold + softness, value) * opacity;
  ALBEDO = shadow_tint;
  ALPHA = shadow * 0.6;
}

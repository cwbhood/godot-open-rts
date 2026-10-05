shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled,
    shadows_disabled;

// Full-screen fog of war overlay. Each pixel's world position is rebuilt from the depth buffer
// and looked up in the visibility texture drawn by FogOfWar.gd, whose red channel holds
// 0 for never seen ground, about 0.25 for explored ground and 1 for ground in sight.
// Explored and unexplored ground stay readable: they are dimmed and tinted, never blacked out.

#include "res://source/shaders/3d/depth_reconstruction.gdshaderinc"

uniform vec4 color : source_color = vec4(0.03, 0.04, 0.08, 1.0);
uniform sampler2D world_visibility_texture : hint_default_white, filter_linear, repeat_disable;
uniform int texture_units_per_world_unit = 2;
uniform float outer_margin_for_fade_out = 2.0;
uniform bool debug_texture_view = false;
// visibility-texture value of explored ground (FogOfWar.gd fog_circle_color)
uniform float explored_value = 0.25;
// how bright the ground stays, as seen on screen (1.0: untouched)
uniform float explored_brightness : hint_range(0.0, 1.0) = 0.62;
uniform float shroud_brightness : hint_range(0.0, 1.0) = 0.36;
uniform float outside_map_brightness : hint_range(0.0, 1.0) = 0.7;
uniform sampler2D depth_texture : hint_depth_texture;

void vertex()
{
  POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float brightness_for(float visibility)
{
  if (visibility < explored_value)
  {
    return mix(shroud_brightness, explored_brightness, visibility / explored_value);
  }
  return mix(explored_brightness, 1.0, (visibility - explored_value) / (1.0 - explored_value));
}

// alpha of the overlay that leaves 'brightness' of the ground on screen
float alpha_for(float brightness)
{
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
  // blending happens on sRGB-encoded colors
  return 1.0 - brightness;
#else
  // blending happens in linear space before the sRGB conversion
  return 1.0 - pow(brightness, 2.2);
#endif
}

void fragment()
{
  ALBEDO = color.rgb;
  float depth = textureLod(depth_texture, SCREEN_UV, 0.0).x;
  vec3 world = depth_to_world(SCREEN_UV, depth, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
  vec2 map_size =
      vec2(textureSize(world_visibility_texture, 0)) / float(texture_units_per_world_unit);
  vec2 uv = world.xz / map_size;
  // distance outside the playable area, 0 inside
  vec2 outside = max(max(-world.xz, world.xz - map_size), vec2(0.0));
  float outside_distance = max(outside.x, outside.y);

  float visibility = textureLod(world_visibility_texture, clamp(uv, 0.0, 1.0), 0.0).r;
  float brightness = brightness_for(clamp(visibility, 0.0, 1.0));
  float edge = outer_margin_for_fade_out > 0.0
      ? smoothstep(0.0, outer_margin_for_fade_out, outside_distance)
      : step(0.0001, outside_distance);
  brightness = min(brightness, mix(1.0, outside_map_brightness, edge));
  if (depth_is_background(depth))
  {
    brightness = outside_map_brightness;
  }
  ALPHA = alpha_for(brightness);

  if (debug_texture_view && UV.x <= 0.2 && UV.y <= 0.2)
  {
    ALBEDO = textureLod(world_visibility_texture, vec2(UV * 5.0), 0.0).rgb;
    if (UV.x > 0.199 || UV.y > 0.199)
    {
      ALBEDO = vec3(1.0, 0.0, 0.0);
    }
    ALPHA = 1.0;
  }
}

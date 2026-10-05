shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled;

// Soft ink lines around silhouettes for the stylised match look (Look.gd). A full-screen
// quad that compares each pixel's view depth with its neighbours'; works on every renderer
// because it only needs the depth buffer. Lines fade out as the camera zooms out.

#include "res://source/shaders/3d/depth_reconstruction.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform vec4 line_color : source_color = vec4(0.12, 0.09, 0.08, 0.6);
uniform float thickness = 1.0;
uniform float depth_threshold = 0.6;
uniform float fade = 1.0;

void vertex()
{
  POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float view_depth(vec2 uv, mat4 inv_projection)
{
  float depth = textureLod(depth_texture, uv, 0.0).x;
  return -depth_to_view(uv, depth, inv_projection).z;
}

void fragment()
{
  mat4 inv_projection = inverse(PROJECTION_MATRIX);
  vec2 px = thickness / VIEWPORT_SIZE;
  float center = view_depth(SCREEN_UV, inv_projection);
  float d1 = view_depth(SCREEN_UV + vec2(px.x, 0.0), inv_projection);
  float d2 = view_depth(SCREEN_UV - vec2(px.x, 0.0), inv_projection);
  float d3 = view_depth(SCREEN_UV + vec2(0.0, px.y), inv_projection);
  float d4 = view_depth(SCREEN_UV - vec2(0.0, px.y), inv_projection);
  // only the far side of an edge draws, so lines sit on the background around an object
  float step_out = max(max(d1, d2), max(d3, d4)) - center;
  // second difference ignores smooth slopes (ground seen at an angle)
  float laplace = abs(d1 + d2 + d3 + d4 - 4.0 * center);
  float edge = smoothstep(depth_threshold, depth_threshold * 2.5, min(step_out, laplace));
  ALBEDO = line_color.rgb;
  ALPHA = edge * line_color.a * fade;
}

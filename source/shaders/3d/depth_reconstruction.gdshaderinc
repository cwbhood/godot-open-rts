// Rebuilds positions from the depth buffer in the renderer's own conventions.
// Forward+ and Mobile use reversed Z with NDC depth in <0; 1> (far plane at 0), while the
// Compatibility (OpenGL) renderer keeps NDC depth in <-1; 1> with the far plane at 1.
// Using the Vulkan formula under OpenGL puts every pixel in the wrong place, which turned the
// fog of war overlay fully black in OpenGL runs.

vec3 depth_to_ndc(vec2 screen_uv, float depth)
{
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
  return vec3(screen_uv, depth) * 2.0 - 1.0;
#else
  return vec3(screen_uv * 2.0 - 1.0, depth);
#endif
}

bool depth_is_background(float depth)
{
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
  return depth >= 1.0;
#else
  return depth <= 0.0;
#endif
}

vec3 depth_to_view(vec2 screen_uv, float depth, mat4 inv_projection)
{
  vec4 view = inv_projection * vec4(depth_to_ndc(screen_uv, depth), 1.0);
  return view.xyz / view.w;
}

vec3 depth_to_world(vec2 screen_uv, float depth, mat4 inv_projection, mat4 inv_view)
{
  return (inv_view * vec4(depth_to_view(screen_uv, depth, inv_projection), 1.0)).xyz;
}

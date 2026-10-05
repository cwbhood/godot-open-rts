shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, unshaded;

// Cloud layer drawn at altitude. It only shows when the camera is zoomed out ('visibility' is
// driven by Atmosphere.gd from the camera size). The same texture and offsets drive the cloud
// shadow overlay, so shadows on the ground line up with the clouds above.

uniform sampler2D cloud_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float period = 400.0;
uniform vec2 offset = vec2(0.0);
uniform float coverage = 0.4;
uniform float softness = 0.18;
uniform float visibility = 0.0;
uniform vec3 lit_color : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 shade_color : source_color = vec3(0.62, 0.64, 0.72);
// kept translucent: the map must stay readable through the clouds when zoomed out
uniform float max_opacity = 0.45;

varying vec3 world_position;

void vertex()
{
  world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float density(vec2 world_xz)
{
  vec2 uv = (world_xz - offset) / period;
  float base = texture(cloud_texture, uv).r;
  float detail = texture(cloud_texture, uv * 4.3 + vec2(0.37, 0.11)).r;
  float value = base * 0.82 + detail * 0.18;
  float threshold = 1.0 - coverage;
  return smoothstep(threshold, threshold + softness, value);
}

void fragment()
{
  float d = density(world_position.xz);
  // fake self-shadowing: denser cores are darker, edges glow in the sun
  float core = density(world_position.xz + vec2(6.0, 6.0));
  vec3 color = mix(lit_color, shade_color, clamp(core * 0.7, 0.0, 1.0) * d);
  ALBEDO = color;
  ALPHA = d * visibility * max_opacity;
}

shader_type canvas_item;

// Full-screen finishing pass of the match look (source/match/environment/Look.gd), drawn over
// the 3D world and under the HUD: split-tone colour grade, a soft tilt-shift blur at the top
// and bottom of the screen, gentle sharpening, vignette and film grain. Every effect is off at 0.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform vec3 shadow_tint : source_color = vec3(0.5);
uniform vec3 highlight_tint : source_color = vec3(0.5);
uniform float split_tone = 0.0;
uniform float lift = 0.0;
uniform float gamma = 1.0;
uniform float gain = 1.0;
uniform float tilt_shift = 0.0;
uniform float tilt_shift_band = 0.35;
uniform float sharpen = 0.0;
uniform float vignette = 0.0;
uniform float grain = 0.0;

float luma(vec3 c)
{
  return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float hash12(vec2 p)
{
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void fragment()
{
  vec2 uv = SCREEN_UV;
  vec3 color = textureLod(screen_texture, uv, 0.0).rgb;

  if (sharpen > 0.0)
  {
    vec2 px = SCREEN_PIXEL_SIZE;
    vec3 blur = (textureLod(screen_texture, uv + vec2(px.x, 0.0), 0.0).rgb
        + textureLod(screen_texture, uv - vec2(px.x, 0.0), 0.0).rgb
        + textureLod(screen_texture, uv + vec2(0.0, px.y), 0.0).rgb
        + textureLod(screen_texture, uv - vec2(0.0, px.y), 0.0).rgb) * 0.25;
    color = max(color + (color - blur) * sharpen, vec3(0.0));
  }

  if (tilt_shift > 0.0)
  {
    // in focus around the middle of the screen, a little lower than the centre
    float away = max(abs(uv.y - 0.55) - tilt_shift_band * 0.5, 0.0);
    float lod = clamp(away * 9.0 * tilt_shift, 0.0, 3.0);
    if (lod > 0.01)
    {
      color = textureLod(screen_texture, uv, lod).rgb;
    }
  }

  // lift / gamma / gain, then shadows and highlights pushed toward their tints
  color = max(color * gain + lift * (1.0 - color), vec3(0.0));
  color = pow(color, vec3(1.0 / max(gamma, 0.01)));
  float l = clamp(luma(color), 0.0, 1.0);
  vec3 tint = mix(shadow_tint, highlight_tint, smoothstep(0.15, 0.85, l));
  color = mix(color, color * tint * 2.0, split_tone);

  if (vignette > 0.0)
  {
    vec2 d = (uv - 0.5) * vec2(1.0, 0.75);
    color *= 1.0 - vignette * smoothstep(0.18, 0.62, dot(d, d) * 2.2);
  }
  if (grain > 0.0)
  {
    float n = hash12(FRAGCOORD.xy + fract(TIME * 7.13) * 917.0) - 0.5;
    color += n * grain * (1.0 - l * 0.6);
  }
  COLOR = vec4(color, 1.0);
}

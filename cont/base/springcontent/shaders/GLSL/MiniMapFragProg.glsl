#version 130

uniform sampler2D shadingTex;
uniform sampler2D minimapTex;
uniform sampler2D infomapTex;

in vec2 vTexCoords;

uniform vec2 uvMult;
uniform float infotexMul;
// LOS grade (see LosGradeApply). infoLosGrade is 1 in "los" mode,
// infoStrength is InfoTexStrength, infoAnimTime is game seconds.
uniform float infoLosGrade;
uniform float infoStrength;
uniform float infoAnimTime;

out vec4 fragColor;
/***********************************************************************/
// LOS info-texture grade (explicit level codes)
//
// In "los" mode a game's infoLOS shader that writes explicit codes stores:
//   R  intel level code, max() over the levels a texel has:
//        0 fog, 1/3 radar, 2/3 air-only LOS, 1 ground LOS
//      (there is no never-seen state; fog is the lowest level)
//   G  jammer coverage, 0..1, independent of the level
//   B  format marker, 1. A texel with B < 0.75 is a legacy gray overlay
//      and keeps the old additive formula.
// Codes are linear, so bilinear filtering and the combiner's temporal blend
// land between two adjacent levels and decode to a value between their
// factors, never to a third level.
//
// Per-level factors (luminance multiplier, saturation multiplier, blue add):
//   ground 1.00 1.00 +0.00   air 0.88 0.85 +0.00
//   radar  0.72 0.65 +0.01   fog 0.52 0.45 +0.02
// infoStrength (springsetting InfoTexStrength, 0..1.25) scales each factor's
// distance from neutral: f' = 1 + (f - 1) * strength. RGB is scaled
// together (hue kept); luminance never drops below min(0.06, original).
// Jam multiplies luminance by ~0.92 with a slow +/-3% world-space pulse.
// Keep in sync: SMFFragProg, GrassFragProg, GroundDecalsFragProg,
// MiniMapFragProg, BumpWaterFS.

const vec3  LOSG_LUMA  = vec3(0.2126, 0.7152, 0.0722);
const vec4  LOSG_LUM   = vec4(0.52, 0.72, 0.88, 1.00); // fog, radar, air, ground
const vec4  LOSG_SAT   = vec4(0.45, 0.65, 0.85, 1.00);
const vec4  LOSG_BLUE  = vec4(0.02, 0.01, 0.00, 0.00);
const float LOSG_FLOOR = 0.06;
const float LOSG_JAM   = 0.92;

bool LosGradeIsCoded(vec3 info) { return (info.b >= 0.75); }

float LosGradeJamPhase(vec2 worldXZ, float t) {
	return dot(worldXZ, vec2(0.012, 0.009)) - t * 0.40;
}

vec3 LosGradeApply(vec3 col, vec3 info, float strength, float jamPhase) {
	strength = clamp(strength, 0.0, 1.25);

	// how far the code reaches into radar, air and ground (each 0..1)
	vec3 reach = clamp(vec3(clamp(info.r, 0.0, 1.0) * 3.0) - vec3(0.0, 1.0, 2.0), 0.0, 1.0);

	float lumMul = LOSG_LUM.x  + dot(reach, LOSG_LUM.yzw  - LOSG_LUM.xyz );
	float satMul = LOSG_SAT.x  + dot(reach, LOSG_SAT.yzw  - LOSG_SAT.xyz );
	float blue   = LOSG_BLUE.x + dot(reach, LOSG_BLUE.yzw - LOSG_BLUE.xyz);

	float jamMul = mix(1.0, LOSG_JAM * (0.97 + 0.03 * sin(jamPhase)), clamp(info.g, 0.0, 1.0));

	lumMul = 1.0 + (lumMul - 1.0) * strength;
	satMul = 1.0 + (satMul - 1.0) * strength;
	jamMul = 1.0 + (jamMul - 1.0) * strength;
	blue  *= strength;

	float lum0 = dot(col, LOSG_LUMA);
	vec3 graded = mix(vec3(lum0), col, satMul) * (lumMul * jamMul);
	float lum1 = dot(graded, LOSG_LUMA);
	graded *= max(lum1, min(LOSG_FLOOR, lum0)) / max(lum1, 1.0e-5);
	graded.b += blue;
	return graded;
}

void main()
{
	const float depthBias = -2.0;

	vec4 shadingColor = texture(shadingTex, vTexCoords                    );
	vec4 minimapColor = texture(minimapTex, vTexCoords         , depthBias);
	vec4 infoSample   = texture(infomapTex, vTexCoords * uvMult, depthBias);

	fragColor = shadingColor * minimapColor;

	if (infotexMul > 0.0 && infoLosGrade > 0.5 && LosGradeIsCoded(infoSample.rgb)) {
		// minimap is ~200x smaller than the world; slow the jam pulse in uv space
		fragColor.rgb = LosGradeApply(fragColor.rgb, infoSample.rgb, infoStrength, LosGradeJamPhase(vTexCoords * 1024.0, infoAnimTime));
	} else {
		fragColor += ((infoSample - vec4(0.5)) * infotexMul);
	}
}
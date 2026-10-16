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
// In "los" mode a game's infoLOS shader that writes explicit codes stores,
// per texel, with no temporal blending:
//   R  intel level code, exactly one of 0 fog, 1/3 radar, 2/3 air-only LOS,
//      1 ground LOS (the max() over the levels present at that texel;
//      there is no never-seen state)
//   G  jammer coverage, 0..1, independent of the level
//   B  format marker, 1. If any texel of the 2x2 footprint has B < 0.75 the
//      caller keeps the legacy additive formula.
// The code must not be filtered before decoding (a fog-to-ground edge would
// pass through 1/3 and 2/3 and draw fake radar/air bands), so the 2x2
// footprint is fetched with texelFetch at LOD 0, each texel is decoded to
// its factors, and the factors are bilinearly blended. That is the only
// smoothing; edges fade between the two real levels.
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

float LosGradeJamPhase(vec2 worldXZ, float t) {
	return dot(worldXZ, vec2(0.012, 0.009)) - t * 0.40;
}

// one unfiltered texel -> vec4(lumMul, satMul, blueAdd, jam), unscaled
vec4 LosGradeDecodeTexel(vec3 texel) {
	float level = floor(clamp(texel.r, 0.0, 1.0) * 3.0 + 0.5);
	vec4 sel = vec4(equal(vec4(level), vec4(0.0, 1.0, 2.0, 3.0)));
	return vec4(dot(sel, LOSG_LUM), dot(sel, LOSG_SAT), dot(sel, LOSG_BLUE), clamp(texel.g, 0.0, 1.0));
}

// Decode the 2x2 texel footprint of uv, then blend the decoded factors.
// Returns false when the texture does not hold explicit codes.
bool LosGradeFetch(sampler2D tex, vec2 uv, out vec4 factors) {
	ivec2 size = textureSize(tex, 0);
	ivec2 maxi = size - ivec2(1);
	vec2 st = uv * vec2(size) - vec2(0.5);
	vec2 w = fract(st);
	ivec2 i0 = ivec2(floor(st));

	vec3 t00 = texelFetch(tex, clamp(i0              , ivec2(0), maxi), 0).rgb;
	vec3 t10 = texelFetch(tex, clamp(i0 + ivec2(1, 0), ivec2(0), maxi), 0).rgb;
	vec3 t01 = texelFetch(tex, clamp(i0 + ivec2(0, 1), ivec2(0), maxi), 0).rgb;
	vec3 t11 = texelFetch(tex, clamp(i0 + ivec2(1, 1), ivec2(0), maxi), 0).rgb;

	factors = vec4(1.0, 1.0, 0.0, 0.0);
	if (min(min(t00.b, t10.b), min(t01.b, t11.b)) < 0.75)
		return false;

	factors = mix(
		mix(LosGradeDecodeTexel(t00), LosGradeDecodeTexel(t10), w.x),
		mix(LosGradeDecodeTexel(t01), LosGradeDecodeTexel(t11), w.x),
		w.y
	);
	return true;
}

vec3 LosGradeApply(vec3 col, vec4 factors, float strength, float jamPhase) {
	strength = clamp(strength, 0.0, 1.25);

	float jamMul = mix(1.0, LOSG_JAM * (0.97 + 0.03 * sin(jamPhase)), factors.w);

	float lumMul = 1.0 + (factors.x - 1.0) * strength;
	float satMul = 1.0 + (factors.y - 1.0) * strength;
	float blue   = factors.z * strength;
	jamMul = 1.0 + (jamMul - 1.0) * strength;

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

	vec4 losFactors;
	if (infotexMul > 0.0 && infoLosGrade > 0.5 && LosGradeFetch(infomapTex, vTexCoords * uvMult, losFactors)) {
		// minimap is ~200x smaller than the world; slow the jam pulse in uv space
		fragColor.rgb = LosGradeApply(fragColor.rgb, losFactors, infoStrength, LosGradeJamPhase(vTexCoords * 1024.0, infoAnimTime));
	} else {
		fragColor += ((infoSample - vec4(0.5)) * infotexMul);
	}
}
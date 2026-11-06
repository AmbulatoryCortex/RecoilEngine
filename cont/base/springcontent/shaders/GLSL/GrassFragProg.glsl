#version 130
// 130 to match GrassVertProg.glsl
//#define FLAT_SHADING

uniform sampler2D shadingTex;
uniform sampler2D grassShadingTex;
uniform sampler2D bladeTex;

#ifdef HAVE_SHADOWS
	uniform sampler2DShadow shadowMap;
	uniform sampler2D shadowColorTex;
	uniform float groundShadowDensity;
#endif
uniform float infoTexIntensityMul;
// LOS grade (see LosGradeApply). infoLosGrade is 1 in "los" mode,
// infoStrength is InfoTexStrength, infoAnimTime is game seconds.
uniform float infoLosGrade;
uniform sampler2D infoGradeTex; // decoded LOS factors, see LosGradeFetch
uniform float infoStrength;
uniform float infoAnimTime;

#ifdef HAVE_INFOTEX
	uniform sampler2D infoMap;
#endif

uniform samplerCube specularTex;
uniform vec3 specularLightColor;
uniform vec3 ambientLightColor;
uniform vec3 camDir;

varying vec3 normal;
varying vec4 shadingTexCoords;
varying vec2 bladeTexCoords;
varying vec3 ambientDiffuseLightTerm;
#if defined(HAVE_SHADOWS) || defined(SHADOW_GEN)
	varying vec4 shadowTexCoords;
#endif

/***********************************************************************/
// LOS info-texture grade
//
// In "los" mode the game's infoLOS shader may write explicit level codes
// (R 0 fog, 1/3 radar, 2/3 air-only LOS, 1 ground LOS; G jam; B 1 marker).
// CInfoTextureCombiner decodes them once per update into a filterable factor
// texture (infoGradeTex, "$info:losgrade" in Lua):
//   r  luminance multiplier of the texel's level
//   g  saturation multiplier of the texel's level
//   b  jammer coverage
//   r < 0.25: the game wrote legacy gray, use the old additive formula
// Codes are never filtered; only decoded factors are (bilinear + mips here,
// plus a short temporal blend in the combiner), so edges fade between the
// two real levels with one texture lookup per fragment. $info itself holds
// a legacy-compatible gray for Lua consumers.
//
// Per-level factors (luminance multiplier, saturation multiplier, tint):
//   ground 1.00  1.00  neutral
//   air    0.88  0.85  neutral
//   radar  0.76  0.65  (0, 0, +0.008)
//   fog    0.52  0.45  (-0.012, -0.002, +0.044)
// Radar lum is 0.76. Thin rings are bilinear/mip/temporal mixes with fog,
// so a 0.72 plateau measured ~0.66 (~30% fog) and the crater annulus sat
// ~0.03 above the shelf (lit 0.27, annulus 0.16, fog 0.13). Apply already
// multiplies luminance by the sampled factor; saturation does not open
// that gap, and blendAlpha stays 0.75. LosGradeHoldRadar eases the
// fog->radar segment (fog, radar, air and ground are fixed points), so
// that ~30% mix lands near 0.74, about 0.20 on the crater, while a
// resolved ring holds at 0.76. Fog stays 0.52 and ground stays 1.
// Tint is rebuilt from the stored factor. +0.02 blue alone left warm
// rock at B-R ~ -0.016; the fog tint above brings that to ~ +0.02.
// infoStrength scales each factor's distance from neutral:
// f' = 1 + (f - 1) * strength. RGB is scaled together (hue kept).
// Luminance is at least 0.07. A texel under 0.005 is empty: scaling it
// cannot produce a color, so it is lifted with gray. Not min(floor, original).
// Jam multiplies luminance by ~0.92 with a slow +/-3% world-space pulse.
// Keep in sync: SMFFragProg, GrassFragProg, GroundDecalsFragProg,
// MiniMapFragProg, BumpWaterFS, and BAR's shaders/GLSL/include/losgrade.glsl.

const vec3  LOSG_LUMA    = vec3(0.2126, 0.7152, 0.0722);
const float LOSG_FOG_LUM = 0.52;
const float LOSG_RAD_LUM = 0.76;
const float LOSG_AIR_LUM = 0.88;
const float LOSG_FLOOR   = 0.07;
const float LOSG_BLACK   = 0.005; // below this, an RGB scale cannot fill the texel
const float LOSG_JAM     = 0.92;

float LosGradeJamPhase(vec2 worldXZ, float t) {
	return dot(worldXZ, vec2(0.012, 0.009)) - t * 0.40;
}

// Ease-out on (fog, radar). Endpoints and every factor at or above radar
// stay put, so air/ground and the fog shelf do not move. A sample 70% of
// the way up this segment (the mix that read 0.66 against a 0.72 plateau)
// is lifted to 91% of the way.
float LosGradeHoldRadar(float lum, float fogLum, float radarLum) {
	if (lum <= fogLum || lum >= radarLum || radarLum <= fogLum)
		return lum;
	float u = (lum - fogLum) / (radarLum - fogLum);
	float held = 1.0 - (1.0 - u) * (1.0 - u);
	return mix(fogLum, radarLum, held);
}

// Cool bias from the stored factor, before the hold and before strength.
// Fog -> (-0.012, -0.002, +0.044), radar -> (0, 0, +0.008), air/ground -> 0.
vec3 LosGradeTint(float lumMul) {
	vec3 fogTint = vec3(-0.012, -0.002, 0.044);
	vec3 radTint = vec3( 0.000,  0.000, 0.008);
	if (lumMul >= LOSG_AIR_LUM)
		return vec3(0.0);
	if (lumMul >= LOSG_RAD_LUM)
		return radTint * ((LOSG_AIR_LUM - lumMul) / (LOSG_AIR_LUM - LOSG_RAD_LUM));
	float t = clamp((lumMul - LOSG_FOG_LUM) / (LOSG_RAD_LUM - LOSG_FOG_LUM), 0.0, 1.0);
	return mix(fogTint, radTint, t);
}

// One filtered lookup of the decoded factors.
// Returns false when the game wrote legacy gray (use the additive formula).
// factors = (lum mul, sat mul, unused, jam). Tint is derived from lum.
bool LosGradeFetch(sampler2D gradeTex, vec2 uv, out vec4 factors) {
	vec3 g = texture(gradeTex, uv).rgb;
	factors = vec4(g.r, g.g, 0.0, g.b);
	return (g.r >= 0.25);
}

vec3 LosGradeApply(vec3 col, vec4 factors, float strength, float jamPhase) {
	strength = clamp(strength, 0.0, 1.25);

	float jamMul = mix(1.0, LOSG_JAM * (0.97 + 0.03 * sin(jamPhase)), clamp(factors.w, 0.0, 1.0));

	float fogLum = 1.0 + (LOSG_FOG_LUM - 1.0) * strength;
	float radLum = 1.0 + (LOSG_RAD_LUM - 1.0) * strength;
	float lumMul = LosGradeHoldRadar(1.0 + (factors.x - 1.0) * strength, fogLum, radLum);
	float satMul = 1.0 + (factors.y - 1.0) * strength;
	vec3 tint = LosGradeTint(factors.x) * strength;
	jamMul = 1.0 + (jamMul - 1.0) * strength;

	float lum0 = dot(col, LOSG_LUMA);
	vec3 graded = mix(vec3(lum0), col, satMul) * (lumMul * jamMul);
	graded += tint;
	graded = max(graded, vec3(0.0));

	float lum1 = dot(graded, LOSG_LUMA);
	// Absolute floor. A near-black texel has no chroma to scale up.
	if (lum1 < LOSG_BLACK)
		graded += vec3(LOSG_FLOOR - lum1);
	else if (lum1 < LOSG_FLOOR)
		graded *= LOSG_FLOOR / lum1;
	return max(graded, vec3(0.0));
}


void main() {
#ifdef SHADOW_GEN
	{
  #ifdef DISTANCE_FAR
		gl_FragColor = texture2D(bladeTex, bladeTexCoords);
  #else
		gl_FragColor = vec4(1.0);
  #endif
		return;
	}
#endif

	vec4 matColor = texture2D(bladeTex, bladeTexCoords);
	matColor.rgb *= texture2D(grassShadingTex, shadingTexCoords.pq).rgb;
	matColor.rgb *= texture2D(shadingTex, shadingTexCoords.pq).rgb * 2.0;

#if defined(FLAT_SHADING) || defined(DISTANCE_FAR)
	vec3 specular = vec3(0.0);
#else
	vec3 reflectDir = reflect(camDir, normalize(normal));
	vec3 specular   = textureCube(specularTex, reflectDir).rgb;
#endif
	gl_FragColor.rgb = matColor.rgb * ambientDiffuseLightTerm + 0.1 * specular * specularLightColor; //TODO make `0.1` specular distr. customizable?
	gl_FragColor.a   = matColor.a * gl_Color.a;

#ifdef HAVE_SHADOWS
	float shadowCoeff = mix(1.0, shadow2DProj(shadowMap, shadowTexCoords).r, groundShadowDensity);

	gl_FragColor.rgb *= mix(ambientLightColor, vec3(1.0), shadowCoeff);
#endif

#ifdef HAVE_INFOTEX
	{
		vec4 losFactors;
		if (infoLosGrade > 0.5 && LosGradeFetch(infoGradeTex, shadingTexCoords.st, losFactors)) {
			// no world position here; the jam pulse runs in info-texture space
			gl_FragColor.rgb = LosGradeApply(gl_FragColor.rgb, losFactors, infoStrength, LosGradeJamPhase(shadingTexCoords.st * 8192.0, infoAnimTime));
		} else {
			vec3 infoSample = texture2D(infoMap, shadingTexCoords.st).rgb;
			gl_FragColor.rgb += (infoSample * infoTexIntensityMul);
			gl_FragColor.rgb -= (vec3(0.5, 0.5, 0.5) * float(infoTexIntensityMul == 1.0));
		}
	}
#endif

	gl_FragColor.rgb = mix(gl_Fog.color.rgb, gl_FragColor.rgb, gl_FogFragCoord);
}

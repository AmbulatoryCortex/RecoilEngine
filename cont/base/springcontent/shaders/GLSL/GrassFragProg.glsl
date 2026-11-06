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
// Per-level factors (luminance multiplier, saturation multiplier, blue add):
//   ground 1.00 1.00 +0.00   air 0.88 0.85 +0.00
//   radar  0.72 0.65 +0.01   fog 0.52 0.45 +0.02
// The blue add is a function of the level, rebuilt from r (piecewise linear).
// infoStrength (springsetting InfoTexStrength, 0..1.25) scales each factor's
// distance from neutral: f' = 1 + (f - 1) * strength. RGB is scaled
// together (hue kept); after grading, luminance is at least 0.06.
// Jam multiplies luminance by ~0.92 with a slow +/-3% world-space pulse.
// Keep in sync: SMFFragProg, GrassFragProg, GroundDecalsFragProg,
// MiniMapFragProg, BumpWaterFS, and BAR's shaders/GLSL/include/losgrade.glsl.

const vec3  LOSG_LUMA  = vec3(0.2126, 0.7152, 0.0722);
const float LOSG_FLOOR = 0.06;
const float LOSG_JAM   = 0.92;

float LosGradeJamPhase(vec2 worldXZ, float t) {
	return dot(worldXZ, vec2(0.012, 0.009)) - t * 0.40;
}

// blue add from the luminance multiplier: fog .52 -> .02, radar .72 -> .01, air .88 -> 0
float LosGradeBlue(float lumMul) {
	return (lumMul < 0.72) ? mix(0.02, 0.01, (lumMul - 0.52) / 0.20) : (0.01 * clamp((0.88 - lumMul) / 0.16, 0.0, 1.0));
}

// One filtered lookup of the decoded factors.
// Returns false when the game wrote legacy gray (use the additive formula).
bool LosGradeFetch(sampler2D gradeTex, vec2 uv, out vec4 factors) {
	vec3 g = texture(gradeTex, uv).rgb;
	factors = vec4(g.r, g.g, LosGradeBlue(g.r), g.b);
	return (g.r >= 0.25);
}

vec3 LosGradeApply(vec3 col, vec4 factors, float strength, float jamPhase) {
	strength = clamp(strength, 0.0, 1.25);

	float jamMul = mix(1.0, LOSG_JAM * (0.97 + 0.03 * sin(jamPhase)), clamp(factors.w, 0.0, 1.0));

	float lumMul = 1.0 + (factors.x - 1.0) * strength;
	float satMul = 1.0 + (factors.y - 1.0) * strength;
	float blue   = factors.z * strength;
	jamMul = 1.0 + (jamMul - 1.0) * strength;

	float lum0 = dot(col, LOSG_LUMA);
	vec3 graded = mix(vec3(lum0), col, satMul) * (lumMul * jamMul);
	float lum1 = dot(graded, LOSG_LUMA);
	// absolute floor: scale RGB together so luminance is at least LOSG_FLOOR
	graded *= max(lum1, LOSG_FLOOR) / max(lum1, 1.0e-5);
	graded.b += blue;
	return graded;
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

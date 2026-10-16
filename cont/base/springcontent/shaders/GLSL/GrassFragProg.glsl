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
		vec3 infoSample = texture2D(infoMap, shadingTexCoords.st).rgb;
		if (infoLosGrade > 0.5 && LosGradeIsCoded(infoSample)) {
			// no world position here; the jam pulse runs in info-texture space
			gl_FragColor.rgb = LosGradeApply(gl_FragColor.rgb, infoSample, infoStrength, LosGradeJamPhase(shadingTexCoords.st * 8192.0, infoAnimTime));
		} else {
			gl_FragColor.rgb += (infoSample * infoTexIntensityMul);
			gl_FragColor.rgb -= (vec3(0.5, 0.5, 0.5) * float(infoTexIntensityMul == 1.0));
		}
	}
#endif

	gl_FragColor.rgb = mix(gl_Fog.color.rgb, gl_FragColor.rgb, gl_FogFragCoord);
}

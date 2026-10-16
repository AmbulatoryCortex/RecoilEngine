#version 130

#ifdef NOSPRING
	#define SMF_INTENSITY_MULT (210.0 / 255.0)
	#define SMF_TEXSQUARE_SIZE 1024.0
	#define GBUFFER_NORMTEX_IDX 0
	#define GBUFFER_DIFFTEX_IDX 1
	#define GBUFFER_SPECTEX_IDX 2
	#define GBUFFER_EMITTEX_IDX 3
	#define GBUFFER_MISCTEX_IDX 4
#endif

#if (GL_FRAGMENT_PRECISION_HIGH == 1)
// ancient GL3 ATI drivers confuse GLSL for GLSL-ES and require this
precision highp float;
#else
precision mediump float;
#endif

/***********************************************************************/
// Consts

const float SMF_SHALLOW_WATER_DEPTH     = 10.0;
const float SMF_SHALLOW_WATER_DEPTH_INV = 1.0 / SMF_SHALLOW_WATER_DEPTH;
const float SMF_DETAILTEX_RES           = 0.02;


/***********************************************************************/
// Uniforms + Varyings + Output

in vec3 halfDir;
in float fogFactor;
in vec4 vertexWorldPos;
in vec2 diffuseTexCoords;


uniform sampler2D diffuseTex;
uniform sampler2D normalsTex;
uniform sampler2D detailTex;
#ifndef SMF_ADV_SHADING
	uniform sampler2D shadingTex;
#endif

uniform vec2 specularTexGen; // 1.0/mapSize

#ifdef SMF_ADV_SHADING
	uniform vec2 normalTexGen;   // either 1.0/mapSize (when NPOT are supported) or 1.0/mapSizePO2
	uniform vec3 groundAmbientColor;
	uniform vec3 groundDiffuseColor;
	uniform vec3 groundSpecularColor;
	uniform float groundSpecularExponent;
	uniform float groundShadowDensity;

	uniform vec2 mapHeights; // min & max height on the map

	uniform vec4 lightDir;
	uniform vec3 cameraPos;
#endif

uniform sampler2D infoTex;
uniform float infoTexIntensityMul;
// LOS grade (see LosGradeApply). infoLosGrade is 1 in "los" mode,
// infoStrength is InfoTexStrength, infoAnimTime is game seconds.
uniform float infoLosGrade;
uniform float infoStrength;
uniform float infoAnimTime;
uniform vec2 infoTexGen;     // 1.0/(pwr2map{x,z} * SQUARE_SIZE)

#ifdef SMF_SPECULAR_LIGHTING
	uniform sampler2D specularTex;
#endif

#ifdef HAVE_SHADOWS
	uniform sampler2DShadow shadowTex;
	uniform sampler2D shadowColorTex;
	uniform mat4 shadowMat;
#endif

#ifdef SMF_WATER_ABSORPTION
	uniform vec3 waterMinColor;
	uniform vec3 waterBaseColor;
	uniform vec3 waterAbsorbColor;
#endif

#if defined(SMF_DETAIL_TEXTURE_SPLATTING) && !defined(SMF_DETAIL_NORMAL_TEXTURE_SPLATTING)
	uniform sampler2D splatDetailTex;
	uniform sampler2D splatDistrTex;
	uniform vec4 splatTexMults;  // per-channel splat intensity multipliers
	uniform vec4 splatTexScales; // defaults to SMF_DETAILTEX_RES per channel
#endif

#ifdef SMF_DETAIL_NORMAL_TEXTURE_SPLATTING
	uniform sampler2D splatDetailNormalTex1;
	uniform sampler2D splatDetailNormalTex2;
	uniform sampler2D splatDetailNormalTex3;
	uniform sampler2D splatDetailNormalTex4;
	uniform sampler2D splatDistrTex;
	uniform vec4 splatTexMults;  // per-channel splat intensity multipliers
	uniform vec4 splatTexScales; // defaults to SMF_DETAILTEX_RES per channel
#endif
#ifdef SMF_SKY_REFLECTIONS
	uniform samplerCube skyReflectTex;
	uniform sampler2D skyReflectModTex;
#endif

#ifdef SMF_BLEND_NORMALS
	uniform sampler2D blendNormalsTex;
#endif

#ifdef SMF_LIGHT_EMISSION
	uniform sampler2D lightEmissionTex;
#endif

#ifdef SMF_PARALLAX_MAPPING
	uniform sampler2D parallaxHeightTex;
#endif

#if defined(DEFERRED_MODE)
	out vec4 fragData[GBUFFER_MISCTEX_IDX + 1];
#elif defined(SMF_COMBINED_PASS)
	// single rasterization, the forward color sits next to the G-buffer data
	out vec4 fragData[GBUFFER_COLORTEX_IDX + 1];
	#define fragColor fragData[GBUFFER_COLORTEX_IDX]
#else
	out vec4 fragColor;
#endif


/***********************************************************************/
// Helper functions

#ifdef SMF_PARALLAX_MAPPING
vec2 GetParallaxUVOffset(vec2 uv, vec3 dir) {
	vec4 texel = texture2D(parallaxHeightTex, uv);

	// RG: height in [ 0.0, 1.0] (256^2 strata)
	//  B: scale  in [ 0.0, 1.0] (256   strata), eg.  0.04 (~10.0/256.0)
	//  A: bias   in [-0.5, 0.5] (256   strata), eg. -0.02 (~75.0/256.0)
	//
	const float RMUL = 255.0 * 256.0;
	const float GMUL = 256.0;
	const float HDIV = 65536.0;

	float heightValue  = dot(texel.rg, vec2(RMUL, GMUL)) / HDIV;
	float heightScale  = texel.b;
	float heightBias   = texel.a - 0.5;
	float heightOffset = heightValue * heightScale + heightBias;

	return ((dir.xy / dir.z) * heightOffset);
}
#endif


#ifdef SMF_ADV_SHADING
	vec3 GetFragmentNormal(vec2 uv) {
		vec3 normal;
		normal.xz = texture2D(normalsTex, uv).ra;
		normal.y  = sqrt(1.0 - dot(normal.xz, normal.xz));
		return normal;
	}
#endif // SMF_ADV_SHADING

#ifndef SMF_DETAIL_NORMAL_TEXTURE_SPLATTING
vec4 GetDetailTextureColor(vec2 uv) {
	#ifndef SMF_DETAIL_TEXTURE_SPLATTING
		vec2 detailTexCoord = vertexWorldPos.xz * vec2(SMF_DETAILTEX_RES);
		vec4 detailCol = (texture2D(detailTex, detailTexCoord) * 2.0) - 1.0;
	#else
		vec4 splatTexCoord0 = vertexWorldPos.xzxz * splatTexScales.rrgg;
		vec4 splatTexCoord1 = vertexWorldPos.xzxz * splatTexScales.bbaa;
		vec4 splatDetails;
			splatDetails.r = texture2D(splatDetailTex, splatTexCoord0.st).r;
			splatDetails.g = texture2D(splatDetailTex, splatTexCoord0.pq).g;
			splatDetails.b = texture2D(splatDetailTex, splatTexCoord1.st).b;
			splatDetails.a = texture2D(splatDetailTex, splatTexCoord1.pq).a;
			splatDetails   = (splatDetails * 2.0) - 1.0;
		vec4 splatCofac = texture2D(splatDistrTex, uv) * splatTexMults;
		vec4 detailCol = vec4(dot(splatDetails, splatCofac));
	#endif
	return detailCol;
}
#else // SMF_DETAIL_NORMAL_TEXTURE_SPLATTING is defined
vec4 GetSplatDetailTextureNormal(vec2 uv, out vec2 splatDetailStrength) {
	vec4 splatTexCoord0 = vertexWorldPos.xzxz * splatTexScales.rrgg;
	vec4 splatTexCoord1 = vertexWorldPos.xzxz * splatTexScales.bbaa;
	vec4 splatCofac = texture2D(splatDistrTex, uv) * splatTexMults;

	// dot with 1's to sum up the splat distribution weights
	splatDetailStrength.x = min(1.0, dot(splatCofac, vec4(1.0)));

	vec4 splatDetailNormal;
		splatDetailNormal  = ((texture2D(splatDetailNormalTex1, splatTexCoord0.st) * 2.0 - 1.0) * splatCofac.r);
		splatDetailNormal += ((texture2D(splatDetailNormalTex2, splatTexCoord0.pq) * 2.0 - 1.0) * splatCofac.g);
		splatDetailNormal += ((texture2D(splatDetailNormalTex3, splatTexCoord1.st) * 2.0 - 1.0) * splatCofac.b);
		splatDetailNormal += ((texture2D(splatDetailNormalTex4, splatTexCoord1.pq) * 2.0 - 1.0) * splatCofac.a);

	// note: y=0.01 (pointing up) in case all splat-cofacs are zero
	splatDetailNormal.y = max(splatDetailNormal.y, 0.01);

	#ifdef SMF_DETAIL_NORMAL_DIFFUSE_ALPHA
		splatDetailStrength.y = clamp(splatDetailNormal.a, -1.0, 1.0);
	#endif

	// note: .xyz is intentionally not normalized here
	// (the normal will be rotated to worldspace first)
	return splatDetailNormal;
}
#endif

#ifdef SMF_ADV_SHADING
	vec4 GetShadeInt(float groundLightInt, vec3 groundShadowCoeff, float groundDiffuseAlpha) {
		vec4 groundShadeInt = vec4(0.0, 0.0, 0.0, 1.0);

		groundShadeInt.rgb = groundAmbientColor + groundDiffuseColor * (groundLightInt * groundShadowCoeff);
		groundShadeInt.rgb *= vec3(SMF_INTENSITY_MULT);

	#ifdef SMF_VOID_WATER
		// cut out all underwater fragments indiscriminately
		groundShadeInt.a = float(vertexWorldPos.y >= 0.0);
	#endif

	#ifdef SMF_VOID_GROUND
		// assume the map(per)'s diffuse texture provides sensible alphas
		// note that voidground overrides voidwater if *both* are enabled
		// (limiting it to just above-water fragments would be arbitrary)
		groundShadeInt.a = groundDiffuseAlpha;
	#endif

	#ifdef SMF_WATER_ABSORPTION
		// use alpha of groundShadeInt cause:
		// allow voidground maps to create holes in the seabed
		// (SMF_WATER_ABSORPTION == 1 implies voidwater is not
		// enabled but says nothing about the voidground state)
		vec4 waterShadeInt = vec4(waterBaseColor.rgb, groundShadeInt.a);
		if (mapHeights.x <= 0.0) {
			float waterShadeAlpha  = abs(vertexWorldPos.y) * SMF_SHALLOW_WATER_DEPTH_INV;
			float waterShadeDecay  = 0.2 + (waterShadeAlpha * 0.1);
			float vertexStepHeight = min(1023.0, -vertexWorldPos.y);
			float waterLightInt    = min(groundLightInt * 2.0 + 0.4, 1.0);

			// vertex below shallow water depth --> alpha=1
			// vertex above shallow water depth --> alpha=waterShadeAlpha
			waterShadeAlpha = min(1.0, waterShadeAlpha + float(vertexWorldPos.y <= -SMF_SHALLOW_WATER_DEPTH));

			waterShadeInt.rgb -= (waterAbsorbColor.rgb * vertexStepHeight);
			waterShadeInt.rgb  = max(waterMinColor.rgb, waterShadeInt.rgb);
			waterShadeInt.rgb *= vec3(SMF_INTENSITY_MULT * waterLightInt);

			// make shadowed areas darker over deeper water
			waterShadeInt.rgb *= (1.0 - waterShadeDecay * (vec3(1.0) - groundShadowCoeff));

			// if depth is greater than _SHALLOW_ depth, select waterShadeInt
			// otherwise interpolate between groundShadeInt and waterShadeInt
			// (both are already cosine-weighted)
			waterShadeInt.rgb = mix(groundShadeInt.rgb, waterShadeInt.rgb, waterShadeAlpha);
		}
		return mix(groundShadeInt, waterShadeInt, float(vertexWorldPos.y < 0.0));
	#else
		return groundShadeInt;
	#endif
	}
#endif // SMF_ADV_SHADING

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

/***********************************************************************/
// main()

#line 10257

void main() {
	vec2 diffTexCoords = diffuseTexCoords;
	vec2 specTexCoords = vertexWorldPos.xz * specularTexGen;
	vec2 infoTexCoords = vertexWorldPos.xz * infoTexGen;
	#ifdef SMF_ADV_SHADING
		vec2 normTexCoords = vertexWorldPos.xz * normalTexGen;

		// not calculated in the vertex shader to save varying components (OpenGL2.0 allows just 32)
		vec3 cameraDir = vertexWorldPos.xyz - cameraPos;
		vec3 normal = GetFragmentNormal(normTexCoords);
	#endif

	#if defined(SMF_BLEND_NORMALS) || defined(SMF_PARALLAX_MAPPING) || defined(SMF_DETAIL_NORMAL_TEXTURE_SPLATTING)
		// detail-normals are (assumed to be) defined within STN space
		// (for a regular vertex normal equal to <0, 1, 0>, the S- and
		// T-tangents are aligned with Spring's +x and +z (!) axes)
		vec3 tTangent = normalize(cross(normal, vec3(-1.0, 0.0, 0.0)));
		vec3 sTangent = cross(normal, tTangent);
		mat3 stnMatrix = mat3(sTangent, tTangent, normal);
	#endif


	#ifdef SMF_PARALLAX_MAPPING
	{
		// use specular-texture coordinates to index parallaxHeightTex
		// (ie. specularTex and parallaxHeightTex must have equal size)
		// cameraDir does not need to be normalized, x/z and y/z ratios
		// do not change
		vec2 uvOffset = GetParallaxUVOffset(specTexCoords, transpose(stnMatrix) * cameraDir);

		// scale the parallax offset since it is in spectex-space
		diffTexCoords += (uvOffset / (SMF_TEXSQUARE_SIZE * specularTexGen));
		normTexCoords += (uvOffset * (normalTexGen / specularTexGen));
		specTexCoords += (uvOffset);

		normal = GetFragmentNormal(normTexCoords);
	}
	#endif

	#ifdef SMF_BLEND_NORMALS
	{
		vec4 dtSample = texture2D(blendNormalsTex, normTexCoords);
		vec3 dtNormal = (dtSample.xyz * 2.0) - 1.0;

		// convert dtNormal from TS to WS before mixing
		normal = normalize(mix(normal, stnMatrix * dtNormal, dtSample.a));
	}
	#endif

	vec4 detailCol;
	#if !defined(SMF_DETAIL_NORMAL_TEXTURE_SPLATTING) || !defined(SMF_ADV_SHADING)
	{
		detailCol = GetDetailTextureColor(specTexCoords);
	}
	#else
	{
		// x-component modulates mixing of normals
		// y-component contains the detail color (splatDetailNormal.a if SMF_DETAIL_NORMAL_DIFFUSE_ALPHA)
		vec2 splatDetailStrength = vec2(0.0, 0.0);

		// note: splatDetailStrength is an OUT-param
		vec4 splatDetailNormal = GetSplatDetailTextureNormal(specTexCoords, splatDetailStrength);

		detailCol = vec4(splatDetailStrength.y);

		// convert the splat detail normal to world-space, then
		// mix it with the regular one, then normalize it again
		// to get correct specular and diffuse highlights
		normal = normalize(mix(normal, normalize(stnMatrix * splatDetailNormal.xyz), splatDetailStrength.x));
	}
	#endif

#if !defined(DEFERRED_MODE) && defined(SMF_ADV_SHADING)
	float cosAngleDiffuse = clamp(dot(lightDir.xyz, normal), 0.0, 1.0);
	float cosAngleSpecular = clamp(dot(normalize(halfDir), normal), 0.001, 1.0);
#endif

	vec4 diffuseCol = texture2D(diffuseTex, diffTexCoords);
	vec4 specularCol = vec4(0.0, 0.0, 0.0, 1.0);
	vec4 emissionCol = vec4(0.0, 0.0, 0.0, 0.0);

	#if !defined(DEFERRED_MODE) && defined(SMF_SKY_REFLECTIONS)
	{
		// cameraDir does not need to be normalized for reflect()
		vec3 reflectDir = reflect(cameraDir, normal);
		vec3 reflectCol = textureCube(skyReflectTex, reflectDir).rgb;
		vec3 reflectMod = texture2D(skyReflectModTex, specTexCoords).rgb;

		diffuseCol.rgb = mix(diffuseCol.rgb, reflectCol, reflectMod);
	}
	#endif
	// The LOS grade is applied to the albedo before lighting, in every pass:
	// forward, combined and DEFERRED_MODE. The combined pass already wrote
	// this graded albedo to the G-buffer, so the separate deferred pass must
	// grade too, or Lua deferred lighting would light ungraded ground in fog.
	// The legacy additive overlay stays forward-only, as before.
	#if defined(HAVE_INFOTEX)
	{
		vec4 losFactors;
		if (infoLosGrade > 0.5 && LosGradeFetch(infoTex, infoTexCoords, losFactors)) {
			diffuseCol.rgb = LosGradeApply(diffuseCol.rgb, losFactors, infoStrength, LosGradeJamPhase(vertexWorldPos.xz, infoAnimTime));
		}
		#if !defined(DEFERRED_MODE)
		else {
			// increase contrast and brightness for the overlays
			vec3 infoSample = texture2D(infoTex, infoTexCoords).rgb;
			diffuseCol.rgb += (infoSample * infoTexIntensityMul);
			diffuseCol.rgb -= (vec3(0.5, 0.5, 0.5) * float(infoTexIntensityMul == 1.0));
		}
		#endif
	}
	#endif



	vec3 shadowCoeff = vec3(1.0);

	#if !defined(DEFERRED_MODE) && defined(HAVE_SHADOWS)
	{
		vec4 vertexShadowPos = shadowMat * vertexWorldPos;
			vertexShadowPos.xy += vec2(0.5);

		// same as ARB shader: shadowCoeff = 1 - (1 - shadowCoeff) * groundShadowDensity
		vec3 shadowColor = texture(shadowColorTex, vertexShadowPos.xy).rgb;
		shadowCoeff = mix(vec3(1.0), shadow2DProj(shadowTex, vertexShadowPos).r * shadowColor, groundShadowDensity);
	}
	#endif

	#ifndef DEFERRED_MODE
		#ifdef SMF_ADV_SHADING
		{
			// GroundMaterialAmbientDiffuseColor * LightAmbientDiffuseColor
			vec4 shadeInt = GetShadeInt(cosAngleDiffuse, shadowCoeff, diffuseCol.a);

			fragColor.rgb = (diffuseCol.rgb + detailCol.rgb) * shadeInt.rgb;
			fragColor.a = shadeInt.a;
		}
		#else // SMF_ADV_SHADING
		{
			fragColor.rgb = (diffuseCol.rgb + detailCol.rgb) * texture2D(shadingTex, specTexCoords).rgb;
			fragColor.a = diffuseCol.a;
		}
		#endif // SMF_ADV_SHADING
	#endif // DEFERRED_MODE

	#ifdef SMF_LIGHT_EMISSION
	{
		// apply self-illumination aka. glow, not masked by shadows
		emissionCol = texture2D(lightEmissionTex, specTexCoords);

		#ifndef DEFERRED_MODE
		fragColor.rgb = fragColor.rgb * (1.0 - emissionCol.a) + emissionCol.rgb;
		#endif
	}
	#endif

	#ifdef SMF_ADV_SHADING
		#ifdef SMF_SPECULAR_LIGHTING
			specularCol = texture2D(specularTex, specTexCoords);
		#else
			specularCol = vec4(groundSpecularColor, 1.0);
		#endif // SMF_SPECULAR_LIGHTING

		#ifndef DEFERRED_MODE
			// sun specular lighting contribution
			#ifdef SMF_SPECULAR_LIGHTING
				float specularExp  = specularCol.a * 16.0;
			#else
				float specularExp  = groundSpecularExponent;
			#endif
			float specularPow  = pow(cosAngleSpecular, specularExp);

			vec3  specularInt  = specularCol.rgb * specularPow;
				  specularInt *= shadowCoeff;

			fragColor.rgb += specularInt;
		#endif // DEFERRED_MODE
	#endif // SMF_ADV_SHADING


#if defined(DEFERRED_MODE) || defined(SMF_COMBINED_PASS)
	#ifdef SMF_COMBINED_PASS
	// carry the forward alpha so the void-{ground,water} alpha test cuts every output
	fragData[GBUFFER_NORMTEX_IDX] = vec4((normal + vec3(1.0, 1.0, 1.0)) * 0.5, fragColor.a);
	#else
	fragData[GBUFFER_NORMTEX_IDX] = vec4((normal + vec3(1.0, 1.0, 1.0)) * 0.5, 1.0);
	#endif
	fragData[GBUFFER_DIFFTEX_IDX] = diffuseCol + detailCol;
	fragData[GBUFFER_SPECTEX_IDX] = specularCol;
	fragData[GBUFFER_EMITTEX_IDX] = emissionCol;
	fragData[GBUFFER_MISCTEX_IDX] = vec4(0.0, 0.0, 0.0, 0.0);

	// linearly transform the eye-space depths, might be more useful?
	// gl_FragDepth = gl_FragCoord.z / gl_FragCoord.w;
#endif
#ifndef DEFERRED_MODE
	fragColor.rgb = mix(gl_Fog.color.rgb, fragColor.rgb, fogFactor);
#endif
}


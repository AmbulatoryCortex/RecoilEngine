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
// 0 .. 1.25 (springsetting InfoTexStrength, default 1). Scales each LOS
// factor's distance from 1, so 0 leaves albedo alone and 1.25 exaggerates.
uniform float infoStrength;
// Seconds (gu->gameTime). Only the jamming luminance pattern uses it.
uniform float infoAnimTime;
// 1 when the active info-texture mode is "los". Height/path stay on the
// legacy additive formula even though they also use infoTexIntensityMul == 1.
uniform float infoLosGrade;
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
// LOS info-texture grade
//
// Legacy LOS mode did `diffuse += info - 0.5`. That is an absolute offset,
// so a dark albedo (0.05) loses most of its value while a bright one barely
// moves. This path replaces that offset with per-level multipliers.
//
// There is no never-seen state. The darkest intel is fog; anything at or
// below the fog center is fog, anything at or above ground LOS is ground.
//
// Two encodings of the same four levels can show up in a sampled texel.
//
// DIRECT centers (the levels this prototype was asked to recognize), as the
// gray value stored in the info texture:
//   fog 0.44, radar 0.46, air-only 0.52, ground LOS 0.60
//
// BLENDED centers are what Beyond All Reason actually stores today.
//   luaui/Widgets/gfx_los_colors.lua at default opacity 0.66 writes
//     fog   (alwaysColor) = 0.40 * 0.66           = 0.264
//     radar (radarColor2) = 0.40 * lerp(0.66,1,.5) = 0.332
//     los                 = 0.60                   (not scaled by opacity)
//     jam                 = (0.03, -0.03, -0.03)
//   shaders/GLSL/infoLOS.lua (the game's copy, not this repo's) then does
//     color = max(fog, radar2 * radar, los * mix(groundLos, airLos, 0.2))
//     color += jam * jamming
//     alpha = 0.03
//   Air-only (groundLos = 0, airLos = 1) is los * 0.2 = 0.12, which loses
//   the max() to fog, so current BAR does not emit a distinct air-only gray.
//   The only intermediate between radar (~0.33) and full LOS (0.60) is
//   ground-without-air: 0.60 * mix(1, 0, 0.2) = 0.48. That sample is graded
//   as air-only (the requested ~0.52). Full coverage of both LOS textures
//   stays 0.60 and is ground.
//   CInfoTextureCombiner clears the target to 0.5 and blends
//   SRC_ALPHA, ONE_MINUS_SRC_ALPHA, so the stored texel is
//   mix(0.5, color, 0.03) and every level lands near 0.49..0.51.
//   RGB10 plus that 0.03 scale leaves fog and radar about two code points
//   apart; mip filtering averages them further. Anchors assume opacity 0.66
//   and shift if the player changes the LOS opacity slider (los itself does
//   not move; fog and radar do).
//
// A texel inside (0.480, 0.520) is un-blended with alpha 0.03 and classified
// on the BAR centers, unless that reconstruction falls outside the BAR color
// range (a sample near 0.51 un-blends above 0.75 and stays on the direct
// scale; 0.52 itself is already outside the envelope). Otherwise the direct
// centers are used.
//
// Jamming is not a fifth level and is not added as color. BAR's tint is
// +R -G -B with G ~ B. That excess is stripped before the gray is measured,
// then applied here as a luminance multiply of about 0.92 (-8%) plus a slow
// world-space sine. The diagonal fog lines are not drawn by the engine.
// BAR draws them in screen space from
//   luaui/Widgets/gfx_fog_diaglines_gl4.lua
//   luaui/Shaders/fog_diaglines.frag.glsl
// (moved out of the game's infoLOS.lua; this repo's infoLOS.lua never had
// them). They composite on top of this grade and are left alone.
//
// Each claimed level proposes a factor. Overlapping claims (the middle half
// of the gap between two adjacent centers, and any filtered texel that still
// lands in that band) resolve with max() of the factors, so the higher intel
// wins the border. Filtering that already averaged two colors into a third
// gray cannot be undone from one sample; that gray is classified as whichever
// center it landed on.
//
// Factors, then infoStrength: f' = 1 + (f - 1) * infoStrength.
//   ground LOS  lum 1.00  sat 1.00
//   air-only    lum 0.88  sat 0.85
//   radar       lum 0.72  sat 0.65  blue +0.01
//   fog         lum 0.52  sat 0.45  blue +0.02  albedo-luminance floor 0.06
// RGB is scaled by one multiplier (hue kept). Saturation is mixed toward the
// Rec.709 luminance before that scale. Nothing is clamped per channel.
// The fog floor is applied to albedo, before lighting, by scaling RGB
// together. Non-LOS modes (mul != 1, or infoLosGrade == 0, or a texel that
// is not one of these grays) keep the old additive formula.

const vec3 LOS_LUMA = vec3(0.2126, 0.7152, 0.0722);
const vec4 LOS_DIRECT_CENTERS = vec4(0.44, 0.46, 0.52, 0.60);
const vec4 LOS_BAR_CENTERS    = vec4(0.264, 0.332, 0.480, 0.600);
const float LOS_BLEND_ALPHA   = 0.03;
// Order is fog, radar, air-only, ground.
const vec4 LOS_LUM  = vec4(0.52, 0.72, 0.88, 1.00);
const vec4 LOS_SAT  = vec4(0.45, 0.65, 0.85, 1.00);
const vec4 LOS_BLUE = vec4(0.02, 0.01, 0.00, 0.00);

float InfoScaleFromNeutral(float factor, float strength)
{
	return 1.0 + (factor - 1.0) * strength;
}

void LosLevelWeights(float level, vec4 centers, out vec4 w)
{
	float gap;
	float mid;
	float share;

	w = vec4(0.0);
	if (level <= centers.x) {
		w.x = 1.0;
		return;
	}
	if (level >= centers.w) {
		w.w = 1.0;
		return;
	}

	// fog .. radar
	gap = centers.y - centers.x;
	mid = 0.5 * (centers.x + centers.y);
	share = 0.25 * gap;
	if (level <= centers.y) {
		if (level < mid - share)
			w.x = 1.0;
		else if (level > mid + share)
			w.y = 1.0;
		else {
			w.x = 1.0;
			w.y = 1.0;
		}
		return;
	}

	// radar .. air-only
	gap = centers.z - centers.y;
	mid = 0.5 * (centers.y + centers.z);
	share = 0.25 * gap;
	if (level <= centers.z) {
		if (level < mid - share)
			w.y = 1.0;
		else if (level > mid + share)
			w.z = 1.0;
		else {
			w.y = 1.0;
			w.z = 1.0;
		}
		return;
	}

	// air-only .. ground
	gap = centers.w - centers.z;
	mid = 0.5 * (centers.z + centers.w);
	share = 0.25 * gap;
	if (level < mid - share)
		w.z = 1.0;
	else if (level > mid + share)
		w.w = 1.0;
	else {
		w.z = 1.0;
		w.w = 1.0;
	}
}

// Strip BAR's jam tint (+R, -G, -B, G ~ B) and return the gray intel level.
// `blended` selects the post-combiner scale (the tint was multiplied by alpha).
void SeparateLosJam(vec3 info, bool blended, out float jam, out float gray)
{
	float gb = 0.5 * (info.g + info.b);
	float rg = info.r - info.g;
	float rb = info.r - info.b;
	float gbDelta = abs(info.g - info.b);
	float gbTol = blended ? 0.004 : 0.03;
	// Full jam is 0.06 of R-G in shader space, ~0.0018 after the 0.03 blend
	// (about two RGB10 steps). Ignore a single code point or the grade
	// flickers. Partial jam below that floor is not recoverable once blended.
	// A larger split is some other overlay, not jamming.
	float rgFull = blended ? (0.06 * LOS_BLEND_ALPHA) : 0.06;
	float rgMin = blended ? 0.0015 : 0.015;
	float rgMax = blended ? 0.01 : 0.12;
	bool jamLike = (gbDelta <= gbTol) && (rg >= rgMin) && (rb >= rgMin) && (rg <= rgMax) && (rb <= rgMax);

	jam = jamLike ? clamp(rg / rgFull, 0.0, 1.0) : 0.0;
	gray = jamLike ? (gb + (0.5 * rgFull) * jam) : dot(info, vec3(1.0 / 3.0));
}

bool DecodeLosGrade(vec3 info, float strength, vec2 worldXZ, inout vec3 graded)
{
	float chroma = max(info.r, max(info.g, info.b)) - min(info.r, min(info.g, info.b));
	float mean = dot(info, vec3(1.0 / 3.0));
	bool inEnvelope = (mean > 0.480) && (mean < 0.520);

	float jam;
	float gray;
	SeparateLosJam(info, inEnvelope, jam, gray);

	bool blended = false;
	float level = gray;
	if (inEnvelope) {
		float shaderGray = 0.5 + (gray - 0.5) / LOS_BLEND_ALPHA;
		// A direct sample just under 0.52 un-blends to ~1.1 and is rejected,
		// so it stays on the direct scale. Exactly 0.52 is outside the envelope.
		if ((shaderGray >= -0.02) && (shaderGray <= 0.75)) {
			blended = true;
			level = shaderGray;
		}
	}

	if (blended) {
		if ((jam == 0.0) && (chroma > 0.02))
			return false;
		if ((level < -0.02) || (level > LOS_BAR_CENTERS.w + 0.08))
			return false;
	} else {
		if ((jam == 0.0) && (chroma > 0.08))
			return false;
		if ((level < LOS_DIRECT_CENTERS.x - 0.04) || (level > LOS_DIRECT_CENTERS.w + 0.05))
			return false;
	}

	vec4 centers = blended ? LOS_BAR_CENTERS : LOS_DIRECT_CENTERS;
	vec4 w;
	LosLevelWeights(level, centers, w);

	float lumMul = 0.0;
	float satMul = 1.0;
	float blue = 0.0;
	bool fogWon = false;

	// max() of the claimed factors. Lum (and sat) increase with intel, so the
	// highest claim also donates that level's saturation and blue tint.
	if (w.x > 0.0) {
		lumMul = InfoScaleFromNeutral(LOS_LUM.x, strength);
		satMul = InfoScaleFromNeutral(LOS_SAT.x, strength);
		blue = LOS_BLUE.x;
		fogWon = true;
	}
	if (w.y > 0.0) {
		float lum = InfoScaleFromNeutral(LOS_LUM.y, strength);
		if (lum >= lumMul) {
			lumMul = lum;
			satMul = InfoScaleFromNeutral(LOS_SAT.y, strength);
			blue = LOS_BLUE.y;
			fogWon = false;
		}
	}
	if (w.z > 0.0) {
		float lum = InfoScaleFromNeutral(LOS_LUM.z, strength);
		if (lum >= lumMul) {
			lumMul = lum;
			satMul = InfoScaleFromNeutral(LOS_SAT.z, strength);
			blue = LOS_BLUE.z;
			fogWon = false;
		}
	}
	if (w.w > 0.0) {
		float lum = InfoScaleFromNeutral(LOS_LUM.w, strength);
		if (lum >= lumMul) {
			lumMul = lum;
			satMul = InfoScaleFromNeutral(LOS_SAT.w, strength);
			blue = LOS_BLUE.w;
			fogWon = false;
		}
	}

	float lum = dot(graded, LOS_LUMA);
	graded = mix(vec3(lum), graded, satMul);
	graded *= lumMul;

	// -8% luminance, then a slow +/-3% world-space pulse. Scaled like the
	// other factors: distance from 1 moves with infoStrength.
	float phase = dot(worldXZ, vec2(0.012, 0.009)) - infoAnimTime * 0.40;
	float pattern = 0.97 + 0.03 * sin(phase);
	float jamFactor = mix(1.0, 0.92 * pattern, jam);
	graded *= InfoScaleFromNeutral(jamFactor, strength);

	if (fogWon) {
		float fogLum = dot(graded, LOS_LUMA);
		float lifted = max(fogLum, 0.06);
		float liftT = clamp(strength, 0.0, 1.0);
		graded *= mix(1.0, lifted / max(fogLum, 1.0e-4), liftT);
	}

	graded.b += blue * strength;
	return true;
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
	#if !defined(DEFERRED_MODE) && defined(HAVE_INFOTEX)
	{
		vec3 infoSample = texture2D(infoTex, infoTexCoords).rgb;
		// Metal and any other non-LOS mode keep the additive overlay.
		// mul == 1 is the historical LOS-style path (the flat -0.5); height
		// and path also land here, so infoLosGrade restricts the new grade
		// to the "los" mode. A LOS texel that is not one of the known grays
		// falls back to that same additive formula.
		if (infoTexIntensityMul != 1.0) {
			diffuseCol.rgb += infoSample * infoTexIntensityMul;
		} else {
			vec3 graded = diffuseCol.rgb;
			float strength = clamp(infoStrength, 0.0, 1.25);
			bool gradedLos = (infoLosGrade > 0.5) && DecodeLosGrade(infoSample, strength, vertexWorldPos.xz, graded);
			if (gradedLos)
				diffuseCol.rgb = graded;
			else {
				diffuseCol.rgb += infoSample;
				diffuseCol.rgb -= vec3(0.5);
			}
		}
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


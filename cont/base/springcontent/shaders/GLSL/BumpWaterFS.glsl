#version 130
/**
 * @project Spring RTS
 * @file bumpWaterFS.glsl
 * @brief An extended bumpmapping water shader
 * @author jK
 *
 * Copyright (C) 2008-2012.  Licensed under the terms of the
 * GNU GPL, v2 or later.
 */

#line 20012

#define CausticDepth 0.5
#define CausticRange 0.45

//////////////////////////////////////////////////
// Uniforms + Varyings

uniform sampler2D normalmap;
uniform sampler2D heightmap;
uniform sampler2D caustic;
uniform sampler2D foam;
uniform sampler2D reflection;
uniform sampler2D refraction;
uniform sampler2D coastmap;
uniform sampler2D depthmap;
uniform sampler2D waverand;
uniform float frame;
uniform vec3 eyePos;

in float eyeVertexZ;
in vec3 eyeVec;
in vec3 ligVec;
in vec3 worldPos;
in vec4 texCoords[6];


vec2 clampedWorldPos = clamp(worldPos.xz, vec2(0.0), (vec2(1.0) / TexGenPlane.xy));

//////////////////////////////////////////////////
// Screen Coordinates (normalized and screen dimensions)

vec2 screenPos = gl_FragCoord.xy - ViewPos;
vec2 screencoord = screenPos * ScreenTextureSizeInverse;
vec2 reftexcoord = screenPos * ScreenInverse;

//////////////////////////////////////////////////
// Depth conversion
#ifdef opt_depth
  float pm14 = gl_ProjectionMatrix[3].z;
  float pm10 = gl_ProjectionMatrix[2].z;

  float ConvertDepthToEyeZ(float d) {
    return (pm14 / (d * -2.0 + 1.0 - pm10));
  }
#endif


//////////////////////////////////////////////////
// shorewaves functions
#ifdef opt_shorewaves
float InvWavesLength = 1.0 / WaveLength;

float smoothlimit(const float x, const float edge) {
	float limitcurv = edge - (mod(x,edge) * edge) / (1.0 - edge);
	return mix(x, limitcurv, step(edge, x));
}

vec4 waveIntensity(const vec4 v) {
	vec4 front = vec4(1.0)-(abs(v - vec4(0.85)))/vec4(1.0-0.85);
	bvec4 bs = lessThan(v, vec4(0.85));
	front = max(front, vec4(bs) * v * 0.5);
	return front;
}

#endif


//////////////////////////////////////////////////
// Shadow

#ifdef opt_shadows
  uniform mat4 shadowMatrix;
  //uniform float shadowDensity;
  uniform sampler2DShadow shadowmap;
  uniform sampler2D shadowColorTex;
#endif

vec3 GetShadowOcclusion(vec3 worldPos) {
#ifdef opt_shadows
	vec4 vertexShadowPos = shadowMatrix * vec4(worldPos, 1.0);
	vertexShadowPos.xy += vec2(0.5, 0.5); // shadowParams.xy
	float sh = shadow2DProj(shadowmap, vertexShadowPos).r;
	vec3 shColor = texture2D(shadowColorTex, vertexShadowPos.xy).rgb;
	return mix(1.0, sh, shadowDensity) * shColor;
#endif
	return vec3(1.0);
}


//////////////////////////////////////////////////
// infotex

#ifdef opt_infotex
  uniform sampler2D infotex;
// LOS grade (see LosGradeApply). infoLosGrade is 1 in "los" mode,
// infoStrength is InfoTexStrength, infoAnimTime is game seconds.
uniform float infoLosGrade;
uniform sampler2D infoGradeTex; // decoded LOS factors, see LosGradeFetch
uniform float infoStrength;
uniform float infoAnimTime;
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

bool InfoTexIsLosCoded(out vec4 factors) {
	factors = vec4(1.0, 1.0, 0.0, 0.0);
#ifdef opt_infotex
	if (infoLosGrade > 0.5)
		return LosGradeFetch(infoGradeTex, ShadingPlane.xy * clampedWorldPos, factors);
#endif
	return false;
}

// legacy additive overlay on the surface color (non-LOS modes, old games)
vec3 ApplyInfoTexLegacy(vec3 surface, float outside) {
#ifdef opt_infotex
	vec2 clampedPotCoords = ShadingPlane.xy * clampedWorldPos;
	vec3 infoSample = texture2D(infotex, clampedPotCoords).rgb;
	surface += mix((infoSample - 0.5) * 0.5, vec3(0.0), outside);
#endif
	return surface;
}

// LOS grade of one water term (surface, reflection or specular)
vec3 ApplyInfoTexLosGrade(vec3 color, vec4 factors, float outside) {
#ifdef opt_infotex
	vec3 graded = LosGradeApply(color, factors, infoStrength, LosGradeJamPhase(clampedWorldPos, infoAnimTime));
	color = mix(graded, color, outside);
#endif
	return color;
}


//////////////////////////////////////////////////
// Helpers

void GetWaterHeight(out float waterdepth, out float invwaterdepth, out float outside, inout vec2 coastdist)
{
	outside = 0.0;

#ifdef opt_shorewaves
	vec3 coast = texture2D(coastmap, texCoords[0].st).rgb;
	coastdist = coast.rg;
	invwaterdepth = coast.b;
#else
	invwaterdepth = texture2D(heightmap, texCoords[0].st).a; // heightmap in alpha channel
#endif

#ifdef opt_endlessocean
	outside = min(1., distance(clampedWorldPos, worldPos.xz));
	invwaterdepth = mix(invwaterdepth, 1.0, step(0.5, outside));
#endif

	waterdepth = 1.0 - invwaterdepth;
}


vec3 GetNormal(out vec3 octave)
{
	vec3 octave1 = texture2D(normalmap, texCoords[1].st).rgb;
	vec3 octave2 = texture2D(normalmap, texCoords[1].pq).rgb;
	vec3 octave3 = texture2D(normalmap, texCoords[2].st).rgb;
	vec3 octave4 = texture2D(normalmap, texCoords[2].pq).rgb;

	float a = PerlinAmp;
	octave1 = (octave1 * 2.0 - 1.0) * a;
	octave2 = (octave2 * 2.0 - 1.0) * a * a;
	octave3 = (octave3 * 2.0 - 1.0) * a * a * a;
	octave4 = (octave4 * 2.0 - 1.0) * a * a * a * a;

	vec3 normal = octave1 + octave2 + octave3 + octave4;
	normal = normalize(normal).xzy;

	octave = octave3;

	return normal;
}


float GetWaterDepthFromDepthBuffer(float waterdepth)
{
#ifdef opt_depth
	// calculate difference between texel-z and fragment-z; convert
	// since both are non-linear mappings from 0=dr.min to 1=dr.max
	// absolute differences larger than 3 elmos are clamped to 1
	float  texZ = ConvertDepthToEyeZ(texture2D(depthmap, screencoord).r);
	float fragZ = ConvertDepthToEyeZ(gl_FragCoord.z);
	#if 0
	float fragZ = eyeVertexZ;
	#endif
	float diffZ = abs(texZ - fragZ) * 0.333;

	return clamp(diffZ, 0.0, 1.0);
#else
	return waterdepth;
#endif
}


vec3 GetShorewaves(vec2 coast, vec3 octave, float waterdepth , float invwaterdepth)
{
	vec3 color = vec3(0.0, 0.0, 0.0);
#ifdef opt_shorewaves
	float coastdist = coast.g + octave.x * 0.1;
	if (coastdist > 0.0) {
		// no shorewaves/foam under terrain (is 0.0 underground, 1.0 else)
		float underground = 1.0 - step(1.0, invwaterdepth);

		vec3 wavefoam = texture2D(foam, texCoords[3].st + octave.xy * WaveFoamDistortion).rgb;
		wavefoam += texture2D(foam, texCoords[3].pq + octave.xy * WaveFoamDistortion).rgb;
		wavefoam *= WaveFoamIntensity;

		// shorewaves
		vec4 waverands = texture2D(waverand, texCoords[4].pq);

		vec4 fi = vec4(0.25, 0.50, 0.75, 1.00);
		vec4 f = fract(fi + frame * 50.0 + (texCoords[1].x + texCoords[1].y) * WaveOffsetFactor);
		f = f * 1.4 - vec4(coastdist);
		f = vec4(1.0) - f * InvWavesLength;
		f = clamp(f, 0.0, 1.0);
		f = waveIntensity(f);
		float intensity = dot(f, waverands) * coastdist;

		float iwd = smoothlimit(invwaterdepth, 0.8);
		intensity *= iwd * 1.5;

		color += wavefoam * underground * intensity;

		// cliff foam
		color += (wavefoam * wavefoam) * (underground * 5.5 * (coast.r * coast.r * coast.r) * (coastdist * coastdist * coastdist * coastdist));
	}
#endif
	return color;
}


vec3 GetReflection(float angle, vec3 normal, inout float fresnel)
{
 	vec3 reflColor = vec3(0.0, 0.0, 0.0);
#ifdef opt_reflection
	// we have to mirror the Y-axis
	reftexcoord  = vec2(reftexcoord.x, 1.0 - reftexcoord.y);
	reftexcoord += vec2(0.0, 3.0 * ScreenInverse.y) + normal.xz * 0.09 * ReflDistortion;

	reflColor = texture2D(reflection, reftexcoord).rgb;

  #ifdef opt_blurreflection
	vec2  v = BlurBase;
	float s = BlurExponent;
	reflColor += texture2D(reflection, reftexcoord.st + v).rgb;
	reflColor += texture2D(reflection, reftexcoord.st + v *s).rgb;
	reflColor += texture2D(reflection, reftexcoord.st + v *s*s).rgb;
	reflColor += texture2D(reflection, reftexcoord.st + v *s*s*s).rgb;
	reflColor += texture2D(reflection, reftexcoord.st + v *s*s*s*s).rgb;
	reflColor += texture2D(reflection, reftexcoord.st + v *s*s*s*s*s).rgb;
	reflColor += texture2D(reflection, reftexcoord.st + v *s*s*s*s*s*s).rgb;
	reflColor *= 0.125;
  #endif

	fresnel = FresnelMin + FresnelMax * pow(angle, FresnelPower);
#endif
	return reflColor;
}

//////////////////////////////////////////////////
// MAIN()

void main()
{
   gl_FragColor.a = 1.0; //note: only rendered with blending iff !opt_refraction

//#define dbg_coastmap
#ifdef dbg_coastmap
    gl_FragColor = vec4(texture2D(coastmap, texCoords[0].st).g);
    return;
#endif


  // GET WATERDEPTH
    float outside = 0.0;
    vec2 coast = vec2(0.0, 0.0);
    float waterdepth, invwaterdepth;
    GetWaterHeight(waterdepth, invwaterdepth, outside, coast);
    float shallowScale = GetWaterDepthFromDepthBuffer(waterdepth);

  // NORMALMAP
    vec3 octave;
    vec3 normal = GetNormal(octave);

    vec3  eVec = normalize(eyeVec);
    float eyeNormalCos = dot(-eVec, normal);
    float angle = (1.0 - abs(eyeNormalCos));

  // SHADOW
    vec3 shadowOcc = GetShadowOcclusion(worldPos + vec3(normal.x, 0.0, normal.z) * 10.0);

  // AMBIENT & DIFFUSE
    vec3 reflectDir   = reflect(normalize(-ligVec), normal);
    float specular    = angle * pow( max(dot(reflectDir, eVec), 0.0) , SpecularPower) * SpecularFactor * shallowScale;
    vec3 SunLow       = SunDir * vec3(1.0, 0.1, 1.0);
    float diffuse     = pow( max( dot(normal, SunLow), 0.0), 3.0) * DiffuseFactor;
    float ambient     = smoothstep(-1.3, 0.0, eyeNormalCos) * AmbientFactor;
    vec3 waterSurface = SurfaceColor.rgb + DiffuseColor * diffuse + vec3(ambient);
    float surfaceMix  = (SurfaceColor.a + diffuse) * shallowScale;
    float refractDistortion = 60.0 * (1.0 - pow(gl_FragCoord.z, 80.0)) * shallowScale;

  // INFOTEX
    vec4 losFactors;
    bool losCoded = InfoTexIsLosCoded(losFactors);
    if (!losCoded)
      waterSurface = ApplyInfoTexLegacy(waterSurface, outside);
    else
      // grade the water's own terms only (surface here, reflection and
      // specular below); refraction is a copy of the already-graded scene
      waterSurface = ApplyInfoTexLosGrade(waterSurface, losFactors, outside);

  // REFRACTION
#ifdef opt_refraction
    vec2 refrUV = screencoord + normal.xz * refractDistortion * ScreenInverse;

    // Sample the screencopy for refraction at the distorted UV coordinate:
    vec3 refrColor = texture2D(refraction, refrUV).rgb;

    // Look up the depth of the distorted UV coordinate
    float  texZ = ConvertDepthToEyeZ(texture2D(depthmap, refrUV).r);
    float fragZ = ConvertDepthToEyeZ(gl_FragCoord.z);

   // If the distorted coordinate is closer to the screen in Z, then set the mixback to 1.0
    float mixback = clamp(texZ - fragZ, 0.0, 1.0);

    // Sample the undistorted refraction screencopy, so we know what to replace it with. 
    vec3 origRefrColor = texture2D(refraction, screencoord).rgb;

    // Replace the distorted screencopy with the original if the fragment is above the water. 
    refrColor = mix(refrColor, origRefrColor, mixback);

    gl_FragColor.rgb = mix(refrColor, waterSurface, 0.1 + surfaceMix * 0.100);
#else
    gl_FragColor.rgb = waterSurface;
    gl_FragColor.a   = surfaceMix + specular;
#endif



  // CAUSTICS
    if (waterdepth > 0.0) {
      vec3 caust = texture2D(caustic, texCoords[0].pq * CausticsResolution).rgb;
  #ifdef opt_refraction
      float caustBlend = smoothstep(CausticRange, 0.0, abs(waterdepth - CausticDepth));
      gl_FragColor.rgb += caust * caustBlend * CausticsStrength;
  #else
      gl_FragColor.a *= min(waterdepth * 4.0, 1.0);
      gl_FragColor.rgb += caust * (1.0 - waterdepth) * 7.5 * CausticsStrength;
  #endif
    }



  // SHORE WAVES
    gl_FragColor.rgb += shadowOcc * GetShorewaves(coast, octave, waterdepth, invwaterdepth);

  // REFLECTION
    // Schlick's approx. for Fresnel term
    float fresnel = 0.0;
    vec3 reflColor = GetReflection(angle, normal, fresnel);
    if (losCoded)
      reflColor = ApplyInfoTexLosGrade(reflColor, losFactors, outside);
    gl_FragColor.rgb = mix(gl_FragColor.rgb, reflColor, fresnel * shallowScale);

  // SPECULAR
    vec3 specularTerm = shadowOcc * specular * SpecularColor;
    if (losCoded)
      specularTerm = ApplyInfoTexLosGrade(specularTerm, losFactors, outside);
    gl_FragColor.rgb += specularTerm;

  // FOG
    float fog = clamp( (gl_Fog.end - abs(gl_FogFragCoord)) * gl_Fog.scale ,0.0,1.0);
    gl_FragColor.rgb = mix(gl_Fog.color.rgb, gl_FragColor.rgb, fog );
}

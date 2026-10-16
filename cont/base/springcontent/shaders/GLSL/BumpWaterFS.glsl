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
uniform float infoStrength;
uniform float infoAnimTime;
#endif
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

bool InfoTexIsLosCoded(out vec4 factors) {
	factors = vec4(1.0, 1.0, 0.0, 0.0);
#ifdef opt_infotex
	if (infoLosGrade > 0.5)
		return LosGradeFetch(infotex, ShadingPlane.xy * clampedWorldPos, factors);
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

// LOS grade on the final water color, after reflection/refraction/specular
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
    gl_FragColor.rgb = mix(gl_FragColor.rgb, reflColor, fresnel * shallowScale);

  // SPECULAR
    gl_FragColor.rgb += shadowOcc * specular * SpecularColor;

  // FOG
    float fog = clamp( (gl_Fog.end - abs(gl_FogFragCoord)) * gl_Fog.scale ,0.0,1.0);
  // LOS grade (after reflection, refraction, caustics and specular)
    if (losCoded)
      gl_FragColor.rgb = ApplyInfoTexLosGrade(gl_FragColor.rgb, losFactors, outside);

    gl_FragColor.rgb = mix(gl_Fog.color.rgb, gl_FragColor.rgb, fog );
}

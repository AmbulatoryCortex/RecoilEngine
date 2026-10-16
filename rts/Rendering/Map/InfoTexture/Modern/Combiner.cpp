/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "Combiner.h"
#include "Game/GlobalUnsynced.h"
#include "Rendering/GlobalRendering.h"
#include "Rendering/Shaders/ShaderHandler.h"
#include "Rendering/Shaders/Shader.h"
#include "Rendering/GL/SubState.h"
#include "Map/ReadMap.h"
#include "Map/BaseGroundDrawer.h"
#include "Rendering/Map/InfoTexture/IInfoTextureHandler.h"
#include "Rendering/Map/InfoTexture/InfoTexture.h"
#include "System/Exceptions.h"
#include "System/Config/ConfigHandler.h"
#include "System/Log/ILog.h"

#include "System/Misc/TracyDefs.h"


// set HighResInfoTexture, because games read that value
CONFIG(bool, HighResInfoTexture).defaultValue(true).deprecated(true);

CInfoTextureCombiner::CInfoTextureCombiner()
: CModernInfoTexture("info")
, disabled(true)
{
	texSize = int2(mapDims.pwr2mapx, mapDims.pwr2mapy);

	GL::TextureCreationParams tcp{
		.reqNumLevels = -1,
		.linearMipMapFilter = false,
		.linearTextureFilter = true,
		.wrapMirror = false
	};

	texture = GL::Texture2D(texSize, GL_RGB10_A2, tcp, false);

	if (FBO::IsSupported()) {
		fbo.Bind();
		fbo.AttachTexture(texture.GetId());
		/*bool status =*/ fbo.CheckStatus("CInfoTextureCombiner");
		glClearColor(0.5f, 0.5f, 0.5f, 1.0f);
		if (fbo.IsValid()) glClear(GL_COLOR_BUFFER_BIT);
		FBO::Unbind();

		// create mipmaps
		auto binding = texture.ScopedBind();
		texture.ProduceMipmaps();
	}

	shader = shaderHandler->CreateProgramObject("[CInfoTextureCombiner]", "CInfoTextureCombiner");

	CreateLosDecode();

	if (!fbo.IsValid() /*|| !shader->IsValid()*/) { // don't check shader (it gets created/switched at runtime)
		throw opengl_error("");
	}
}

CInfoTextureCombiner::~CInfoTextureCombiner()
{
	RECOIL_DETAILED_TRACY_ZONE;
	shaderHandler->ReleaseProgramObject("[CInfoTextureCombiner]", "CInfoTextureCombiner");
	shaderHandler->ReleaseProgramObject("[CInfoTextureCombiner]", "CInfoTextureLosDecode");
}


void CInfoTextureCombiner::CreateLosDecode()
{
	RECOIL_DETAILED_TRACY_ZONE;
	{
		GL::TextureCreationParams tcp{
			.reqNumLevels = 1,
			.wrapMirror = false,
			.minFilter = GL_NEAREST,
			.magFilter = GL_NEAREST
		};
		codeTex = GL::Texture2D(texSize, GL_RGB10_A2, tcp, false);
	}
	{
		GL::TextureCreationParams tcp{
			.reqNumLevels = -1,
			.linearMipMapFilter = false,
			.linearTextureFilter = true,
			.wrapMirror = false
		};
		gradeTex = GL::Texture2D(texSize, GL_RGB10_A2, tcp, false);
	}

	if (FBO::IsSupported()) {
		codeFbo.Bind();
		codeFbo.AttachTexture(codeTex.GetId());
		codeFbo.CheckStatus("CInfoTextureCombiner-codes");
		FBO::Unbind();

		decodeFbo.Bind();
		decodeFbo.AttachTexture(texture.GetId(), GL_TEXTURE_2D, GL_COLOR_ATTACHMENT0);
		decodeFbo.AttachTexture(gradeTex.GetId(), GL_TEXTURE_2D, GL_COLOR_ATTACHMENT1);
		decodeFbo.CheckStatus("CInfoTextureCombiner-decode");
		FBO::Unbind();
	}

	// Level codes: R 0 fog, 1/3 radar, 2/3 air-only, 1 ground (exact, unfiltered),
	// G jammer coverage, B 1 marker. The factors are written to gradeTex and
	// blended over time there (decoded values, never codes), and filtered by
	// the consumers' bilinear lookups. Factor table: see SMFFragProg.glsl.
	//
	// Texels outside the map area of the pwr2 texture (non-pwr2 maps) are
	// never written by the game shader. They decode the nearest map-edge
	// texel instead (clamp-to-edge), so bilinear lookups and mips at the
	// right/bottom map edge never mix in a non-level value.
	//
	// $info (attachment 0) is rebuilt from the engine's own los/airlos/radar
	// textures with the upstream BAR formula and its 0.03 blend, so Lua
	// consumers see exactly the legacy gray.
	const std::string fragmentCode = R"(
		#version 130

		uniform sampler2D codeTex;
		uniform sampler2D losTex;
		uniform sampler2D airLosTex;
		uniform sampler2D radarTex;
		uniform ivec2 mapTexels;
		uniform vec3 alwaysColor;
		uniform vec3 losColor;
		uniform vec3 radarColor2;
		uniform vec3 jamColor;
		uniform float blendAlpha;
		uniform float time;

		in vec2 uv;
		out vec4 fragData[2];

		const vec4 LOS_LUM = vec4(0.52, 0.72, 0.88, 1.00); // fog, radar, air, ground
		const vec4 LOS_SAT = vec4(0.45, 0.65, 0.85, 1.00);

		// upstream BAR infoLOS.lua HIGH_QUALITY getTexel (HighResInfoTexture
		// is deprecated and always true)
		float rand(const in vec2 n) {
			return fract(sin(dot(n, vec2(12.9898, 78.233))) * 43758.5453);
		}
		vec4 getTexel(in sampler2D tex, in vec2 p) {
			vec2 texSize = vec2(textureSize(tex, 0));
			vec4 c = vec4(0.0);
			for (int i = 0; i < 4; i++) {
				vec2 off = vec2(time + float(i) * 0.234567);
				off = (vec2(rand(p.st + off.st), rand(p.ts - off.ts)) * 2.0 - 1.0) / texSize;
				c += texture(tex, p + off);
			}
			c *= 0.25;
			return smoothstep(0.5, 1.0, c);
		}

		void main() {
			ivec2 tc = min(ivec2(gl_FragCoord.xy), mapTexels - ivec2(1));
			vec4 t = texelFetch(codeTex, tc, 0);

			if (t.b < 0.75) {
				// legacy gray from an older game: pass it through untouched
				// (it already carries the game's own temporal blend);
				// r = 0 tells consumers "not coded"
				fragData[0] = vec4(t.rgb, 1.0);
				fragData[1] = vec4(0.0, 0.0, 0.0, 1.0);
				return;
			}

			float level = floor(clamp(t.r, 0.0, 1.0) * 3.0 + 0.5);
			vec4 sel = vec4(equal(vec4(level), vec4(0.0, 1.0, 2.0, 3.0)));
			float jam = clamp(t.g, 0.0, 1.0);

			// upstream BAR legacy gray from the real coverages
			vec2 mapUV = (vec2(tc) + 0.5) / vec2(mapTexels);
			vec4 radarJam = getTexel(radarTex, mapUV);
			float groundlos = getTexel(losTex, mapUV).r;
			float airlos = getTexel(airLosTex, mapUV).r;
			vec3 compat = alwaysColor;
			compat = max(compat, radarColor2 * radarJam.r);
			compat = max(compat, losColor * mix(groundlos, airlos, 0.2));
			compat += jamColor * radarJam.g;

			fragData[0] = vec4(compat, 0.03);
			fragData[1] = vec4(dot(sel, LOS_LUM), dot(sel, LOS_SAT), jam, blendAlpha);
		}
	)";

	decodeShader = shaderHandler->CreateProgramObject("[CInfoTextureCombiner]", "CInfoTextureLosDecode");
	decodeShader->AttachShaderObject(shaderHandler->CreateShaderObject(vertexCode,   "", GL_VERTEX_SHADER));
	decodeShader->AttachShaderObject(shaderHandler->CreateShaderObject(fragmentCode, "", GL_FRAGMENT_SHADER));
	decodeShader->Link();
	if (!decodeShader->IsValid()) {
		LOG_L(L_ERROR, "%s-shader compilation error: %s", decodeShader->GetName().c_str(), decodeShader->GetLog().c_str());
		return;
	}
	decodeShader->Enable();
	decodeShader->SetUniform("codeTex", 0);
	decodeShader->SetUniform("losTex", 1);
	decodeShader->SetUniform("airLosTex", 2);
	decodeShader->SetUniform("radarTex", 3);
	decodeShader->Disable();
	decodeShader->Validate();

	ClearLosTextures();
}


void CInfoTextureCombiner::ClearLosTextures()
{
	RECOIL_DETAILED_TRACY_ZONE;
	if (!codeFbo.IsValid() || !decodeFbo.IsValid())
		return;

	codeFbo.Bind();
	glClearColor(0.5f, 0.5f, 0.5f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	FBO::Unbind();

	// fog factors (lum .52, sat .45, no jam): fails closed (nothing reads as
	// ground LOS before the first decode) and fades up from fog; a coded game
	// never shows the legacy additive path
	decodeFbo.Bind();
	glDrawBuffer(GL_COLOR_ATTACHMENT1);
	glClearColor(0.52f, 0.45f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawBuffer(GL_COLOR_ATTACHMENT0);
	FBO::Unbind();

	auto binding = gradeTex.ScopedBind();
	gradeTex.ProduceMipmaps();
}


void CInfoTextureCombiner::SwitchMode(const std::string& name)
{
	RECOIL_DETAILED_TRACY_ZONE;
	if (name.empty()) {
		disabled = true;

		CreateShader(curMode = "", true);
		return;
	}

	// WTF? fully reloaded from disk on every switch?
	// TODO: allow "info:myluainfotex"
	// pathDrawer->UpdateExtraTexture(texDrawMode, starty, endy, offset, infoTexMem);
	switch (hashString(name.c_str())) {
		case hashString("los"     ): { disabled = !CreateShader("shaders/GLSL/infoLOS.lua"   , true, float4(0.5f, 0.5f, 0.5f, 1.0f)); ClearLosTextures(); } break;
		case hashString("metal"   ): { disabled = !CreateShader("shaders/GLSL/infoMetal.lua" , true, float4(0.0f, 0.0f, 0.0f, 1.0f)); } break;
		case hashString("height"  ): { disabled = !CreateShader("shaders/GLSL/infoHeight.lua"                                      ); } break;
		case hashString("path"    ): { disabled = !CreateShader("shaders/GLSL/infoPath.lua"                                        ); } break;
		case hashString("heat"    ): [[fallthrough]];/*TODO ?*/
		case hashString("flow"    ): [[fallthrough]];/*TODO ?*/
		case hashString("pathcost"): [[fallthrough]];/*TODO ?*/
		default                    : { disabled = !CreateShader(name                                                               ); } break;
	}

	curMode = (disabled) ? "" : name;
}


bool CInfoTextureCombiner::CreateShader(const std::string& filename, const bool clear, const float4 clearColor)
{
	RECOIL_DETAILED_TRACY_ZONE;
	if (clear) {
		// clear
		fbo.Bind();
		glClearColor(clearColor.r, clearColor.g, clearColor.b, clearColor.a);
		if (fbo.IsValid()) glClear(GL_COLOR_BUFFER_BIT);
		FBO::Unbind();

		// create mipmaps
		auto binding = texture.ScopedBind();
		texture.ProduceMipmaps();
	}

	if (filename.empty())
		return false;

	shader->Release();
	return shader->LoadFromLua(filename);
}


void CInfoTextureCombiner::DrawModeShader(FBO& target)
{
	target.Bind();
	glViewport(0,0, texSize.x, texSize.y);

	shader->BindTextures();
	shader->Enable();
	shader->SetUniform("time", gu->gameTime);

	const float isx = 2.0f * (mapDims.mapx / float(mapDims.pwr2mapx)) - 1.0f;
	const float isy = 2.0f * (mapDims.mapy / float(mapDims.pwr2mapy)) - 1.0f;

	// need to keep this old nonsence intact to keep Lua shaders compatible
	glBegin(GL_QUADS);
		glTexCoord2f(0.f, 0.f); glVertex2f(-1.f, -1.f);
		glTexCoord2f(0.f, 1.f); glVertex2f(-1.f, +isy);
		glTexCoord2f(1.f, 1.f); glVertex2f(+isx, +isy);
		glTexCoord2f(1.f, 0.f); glVertex2f(+isx, -1.f);
	glEnd();

	shader->Disable();
	shader->UnbindTextures();

	globalRendering->LoadViewport();
	FBO::Unbind();
}


void CInfoTextureCombiner::DecodeLos()
{
	RECOIL_DETAILED_TRACY_ZONE;
	using namespace GL::State;
	auto state = GL::SubState(
		Blending(GL_TRUE),
		BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA),
		ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE)
	);

	CBaseGroundDrawer* gd = readMap->GetGroundDrawer();
	if (gd == nullptr)
		return;
	const float scale = 1.0f / CBaseGroundDrawer::losColorScale;

	decodeFbo.Bind();
	const GLenum drawBuffers[] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1 };
	glDrawBuffers(2, drawBuffers);
	glViewport(0, 0, texSize.x, texSize.y);

	const auto BindInfo = [](GLenum unit, const char* name) {
		CInfoTexture* itex = infoTextureHandler->GetInfoTexture(name);
		glActiveTexture(unit);
		glBindTexture(GL_TEXTURE_2D, (itex != nullptr) ? itex->GetTexture() : 0);
	};
	BindInfo(GL_TEXTURE1, "los");
	BindInfo(GL_TEXTURE2, "airlos");
	BindInfo(GL_TEXTURE3, "radar");
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, codeTex.GetId());

	decodeShader->Enable();
	decodeShader->SetUniform("mapTexels", mapDims.mapx, mapDims.mapy);
	decodeShader->SetUniform("time", gu->gameTime);
	decodeShader->SetUniform("alwaysColor", gd->alwaysColor[0] * scale, gd->alwaysColor[1] * scale, gd->alwaysColor[2] * scale);
	decodeShader->SetUniform("losColor", gd->losColor[0] * scale, gd->losColor[1] * scale, gd->losColor[2] * scale);
	decodeShader->SetUniform("radarColor2", gd->radarColor2[0] * scale, gd->radarColor2[1] * scale, gd->radarColor2[2] * scale);
	decodeShader->SetUniform("jamColor", gd->jamColor[0] * scale, gd->jamColor[1] * scale, gd->jamColor[2] * scale);
	// temporal smoothing of the *decoded* factors: no edge pop
	// (the compat gray uses the upstream 0.03 blend in the shader)
	decodeShader->SetUniform("blendAlpha", 0.15f);

	vao.Bind();
	glDrawArrays(GL_TRIANGLES, 0, 3);
	vao.Unbind();
	decodeShader->Disable();

	for (GLenum unit: {GL_TEXTURE3, GL_TEXTURE2, GL_TEXTURE1, GL_TEXTURE0}) {
		glActiveTexture(unit);
		glBindTexture(GL_TEXTURE_2D, 0);
	}
	glDrawBuffer(GL_COLOR_ATTACHMENT0);
	globalRendering->LoadViewport();
	FBO::Unbind();

	state.pop();

	auto binding = gradeTex.ScopedBind();
	gradeTex.ProduceMipmaps();
}


void CInfoTextureCombiner::Update()
{
	RECOIL_DETAILED_TRACY_ZONE;

	using namespace GL::State;
	auto state = GL::SubState(
		Blending(GL_TRUE),
		ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE)
	);

	const bool losDecode = (curMode == "los") && codeFbo.IsValid() && decodeFbo.IsValid() && decodeShader != nullptr && decodeShader->IsValid();

	DrawModeShader(losDecode ? codeFbo : fbo);

	state.pop();

	if (losDecode)
		DecodeLos();

	// create mipmaps
	auto binding = texture.ScopedBind();
	texture.ProduceMipmaps();
}

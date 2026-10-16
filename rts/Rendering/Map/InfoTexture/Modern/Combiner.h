/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#ifndef _INFO_TEXTURE_COMBINER_H
#define _INFO_TEXTURE_COMBINER_H

#include "ModernInfoTexture.h"
#include "Rendering/GL/FBO.h"
#include "System/float4.h"
#include <string>


namespace Shader {
	struct IProgramObject;
}


class CInfoTextureCombiner : public CModernInfoTexture
{
public:
	CInfoTextureCombiner();
	~CInfoTextureCombiner() override;

	bool IsEnabled() { return !disabled; }
	// decoded LOS grade factors: r = lum mul, g = sat mul, b = jam; r < 0.25
	// means the game's infoLOS shader wrote legacy gray, not level codes
	GLuint GetLosGradeTexture() const { return gradeTex.GetId(); }
	GLuint GetLosCodeTexture() const { return codeTex.GetId(); }
	const std::string& GetMode() const { return curMode; }
	void SwitchMode(const std::string& name);

public:
	void Update() override;
	bool IsUpdateNeeded() override { return !disabled; }

private:
	bool CreateShader(const std::string& filename, const bool clear = false, const float4 clearColor = float4(0.5f, 0.5f, 0.5f, 1.0f));
	void CreateLosDecode();
	void ClearLosTextures();
	void DrawModeShader(FBO& target);
	void DecodeLos();

private:
	bool disabled;
	std::string curMode;

	// "los" mode: the game shader renders into codeTex (same format and
	// blending as $info, so legacy shaders behave exactly as before), then
	// DecodeLos() turns it into $info (legacy-compatible gray for Lua
	// consumers) and gradeTex (filterable factors for the engine's grade).
	GL::Texture2D codeTex;
	GL::Texture2D gradeTex;
	FBO codeFbo;
	FBO decodeFbo;
	Shader::IProgramObject* decodeShader = nullptr;
};

#endif // _INFO_TEXTURE_COMBINER_H

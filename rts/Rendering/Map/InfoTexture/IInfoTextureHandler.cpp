/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "IInfoTextureHandler.h"
#include "Modern/InfoTextureHandler.h"
#include "Game/GlobalUnsynced.h"
#include "Rendering/Shaders/Shader.h"
#include "Rendering/GlobalRendering.h"
#include "Rendering/GL/FBO.h"
#include "System/Config/ConfigHandler.h"
#include "System/Exceptions.h"
#include "System/Log/ILog.h"

#include "System/Misc/TracyDefs.h"

#include <algorithm>

CONFIG(bool, HighResLos).deprecated(true);
CONFIG(int, ExtraTextureUpdateRate).deprecated(true);

// Read every frame, so Spring.SetConfigFloat applies without a reload.
CONFIG(float, InfoTexStrength)
	.defaultValue(1.0f)
	.minimumValue(0.0f)
	.maximumValue(1.25f)
	.description("Strength of the LOS view grading. 0 shows the map unchanged, 1 applies the per-level luminance/saturation factors, 1.25 exaggerates them.");

decltype(infoTextureHandler) infoTextureHandler = nullptr;

void IInfoTextureHandler::Create()
{
	RECOIL_DETAILED_TRACY_ZONE;
	try {
#ifdef HEADLESS
		infoTextureHandler = std::make_unique<CNullInfoTextureHandler>();
#else
		infoTextureHandler = std::make_unique<CInfoTextureHandler>();
#endif
	} catch (const opengl_error& glerr) {
		infoTextureHandler = nullptr;
		throw glerr;
	}

	LOG("InfoTexture: shaders");
}

void IInfoTextureHandler::SetLosGradeUniforms(Shader::IProgramObject* shader) const
{
	RECOIL_DETAILED_TRACY_ZONE;
	// ground, grass, decals, minimap and water all call this every frame;
	// do the config and mode (string compare) lookups once per draw frame
	if (losGradeCacheFrame != globalRendering->drawFrame) {
		losGradeCacheFrame = globalRendering->drawFrame;
		losGradeCacheStrength = std::clamp(configHandler->GetFloat("InfoTexStrength"), 0.0f, 1.25f);
		losGradeCacheEnabled = InLosMode() ? 1.0f : 0.0f;
	}

	shader->SetUniform("infoLosGrade", losGradeCacheEnabled);
	shader->SetUniform("infoStrength", losGradeCacheStrength);
	shader->SetUniform("infoAnimTime", (gu != nullptr) ? gu->gameTime : 0.0f);
}

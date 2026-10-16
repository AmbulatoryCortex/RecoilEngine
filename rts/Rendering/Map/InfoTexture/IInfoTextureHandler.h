/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

#include "Rendering/GL/myGL.h"
#include "System/type2.h"
#include <string>
#include <cstdint>
#include <memory>


class CInfoTexture;
namespace Shader { struct IProgramObject; }


class IInfoTextureHandler {
// carryovers from the old LegacyInfoTextureHandler
public:
	enum {
		COLOR_R = 2,
		COLOR_G = 1,
		COLOR_B = 0,
		COLOR_A = 3,
	};
	enum BaseGroundDrawMode {
		drawNormal   = 0,
		drawLos      = 1, // L
		drawMetal    = 2, // F4
		drawHeight   = 3, // F1
		drawPathTrav = 4, // F2
		drawPathHeat = 5, // not hotkeyed, command-only
		drawPathFlow = 6, // not hotkeyed, command-only
		drawPathCost = 7, // not hotkeyed, command-only
	};
public:
	static void Create();

public:
	IInfoTextureHandler() {}
	IInfoTextureHandler(const IInfoTextureHandler&) = delete; // no-copy
	virtual ~IInfoTextureHandler() {}

	virtual void Update() = 0;

public:
	virtual bool IsEnabled() const = 0;
	virtual bool InMetalMode() const = 0;

	virtual void DisableCurrentMode() = 0;
	virtual void SetMode(const std::string& name) = 0;
	virtual bool HasMode(const std::string& name) const = 0;
	virtual void ToggleMode(const std::string& name) = 0;
	virtual const std::string& GetMode() const = 0;
	virtual const std::vector<std::string> GetModes() const = 0;

	// True when the active mode is "los". Shaders then grade the scene from
	// the explicit LOS level codes (see SMFFragProg.glsl, LosGradeApply).
	bool InLosMode() const { return (IsEnabled() && GetMode() == "los"); }

	// Sets infoLosGrade, infoStrength (springsetting InfoTexStrength) and
	// infoAnimTime on an enabled shader that samples the info texture.
	void SetLosGradeUniforms(Shader::IProgramObject* shader) const;

	virtual GLuint GetCurrentInfoTexture() const = 0;
	// decoded LOS grade factors (also "$info:losgrade" for Lua), 0 if none
	virtual GLuint GetLosGradeTexture() const = 0;
	virtual int2   GetCurrentInfoTextureSize() const = 0;

public:
	virtual const CInfoTexture* GetInfoTextureConst(const std::string& name) const = 0;
	virtual       CInfoTexture* GetInfoTexture     (const std::string& name)       = 0;

private:
	// per-draw-frame cache for SetLosGradeUniforms
	mutable uint32_t losGradeCacheFrame = ~0u;
	mutable float losGradeCacheStrength = 1.0f;
	mutable float losGradeCacheEnabled = 0.0f;
};

extern std::unique_ptr<IInfoTextureHandler> infoTextureHandler;
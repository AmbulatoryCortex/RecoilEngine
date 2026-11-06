/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

#include "Rendering/Models/3DModelDefs.hpp"

/* Single list of Engine.FeatureSupport entries, shared by LuaConstEngine
 * (all Lua states) and LuaShaderContainer (Lua shader definition files such
 * as shaders/GLSL/infoLOS.lua), so the two cannot drift apart.
 *
 * If possible, entries should be bools that resolve to false in the "old" version
 * and to true in the "new" version; this is because any version beforehand has it
 * "set" to nil which is booleanly false as well. This way games doing the check:
 *
 *  if Engine.FeatureSupport.Foo then
 *
 * will be compatible even on engines that don't yet know about the entry at all.
 *
 * BOOL(name, value) / INT(name, value) / FLOAT(name, value) */
#define RECOIL_ENGINE_FEATURE_SUPPORT(BOOL, INT, FLOAT) \
	BOOL(NegativeGetUnitCurrentCommand, true) \
	BOOL(hasExitOnlyYardmaps, true) \
	INT(rmlUiApiVersion, 1) \
	BOOL(noAutoShowMetal, false) \
	INT(maxPiecesPerModel, MAX_PIECES_PER_MODEL) \
	BOOL(transformsInGL4, true) \
	FLOAT(gunshipCruiseAltitudeMultiplier, 1.5f) /* see https://github.com/beyond-all-reason/spring/issues/1028 */ \
	BOOL(noRefundForConstructionDecay, false) \
	BOOL(noRefundForFactoryCancel, false) \
	BOOL(noOffsetForFeatureID, false) \
	BOOL(noHandicapForReclaim, true) \
	BOOL(groupAddDoesntSelect, true) \
	BOOL(deadTeamsKeepUnitLimit, false) \
	BOOL(reliableLuaMapShaders, true) \
	BOOL(nanoParticleUpdateCallin, true) \
	BOOL(nanoParticlesGL4, true) \
	BOOL(modelVertexColor, true) \
	BOOL(losInfoTexCodes, true)

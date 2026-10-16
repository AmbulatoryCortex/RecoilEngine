/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "LuaConstEngine.h"
#include "LuaFeatureSupport.h"
#include "LuaHandle.h"
#include "LuaUtils.h"
#include "Game/GameVersion.h"
#include "System/Platform/Misc.h"
#include "Rendering/Fonts/glFont.h"
#include "Sim/Misc/CustomColorPalette.h"

/******************************************************************************
 * Engine constants
 * @see rts/Lua/LuaConstEngine.cpp
******************************************************************************/

/***
 * @class FeatureSupport
 * @x_helper
 * @field NegativeGetUnitCurrentCommand boolean Whether Spring.GetUnitCurrentCommand allows negative indices to look from the end
 * @field hasExitOnlyYardmaps boolean Whether yardmaps accept 'e' (exit only) and 'u' (unbuildable, walkable)
 * @field rmlUiApiVersion integer Version of Recoil's rmlUI API
 * @field noAutoShowMetal boolean Whether the engine switches to the metal view when selecting a "build metal extractor" command (yes if false)
 * @field maxPiecesPerModel integer How many pieces supported for 3d models?
 * @field gunshipCruiseAltitudeMultiplier number For gunships, the cruiseAltitude from the unit def is multiplied by this much
 * @field noRefundForConstructionDecay boolean Whether there is no refund for construction decay (100% metal back if false)
 * @field noRefundForFactoryCancel boolean Whether there is no refund for factory cancel (100% metal back if false)
 * @field noOffsetForFeatureID boolean Whether featureID from various interfaces (targetID for Reclaim commands, ownerID from SpringGetGroundDecalOwner, etc) needs to be offset by `Game.maxUnits`
 * @field noHandicapForReclaim boolean Whether handicap is applied to income from reclaim
 * @field groupAddDoesntSelect boolean Whether 'group add' also selects the group (does both if false)
 * @field deadTeamsKeepUnitLimit boolean Whether engine redistributes dead team unitlimit to allies (false) or keeps it as-is (true)
 * @field reliableLuaMapShaders boolean Whether forward-only Lua map shaders activate without a deferred draw and Spring.SetMapShader program swaps refresh cached uniform locations
 * @field nanoParticleUpdateCallin boolean Whether LuaUI receives batched `NanoParticleUpdate` lifecycle events
 * @field nanoParticlesGL4 boolean Whether the engine has the standalone shader-based nano particle effect (the `NanoParticles*` springsettings)
 * @field modelVertexColor boolean Whether glTF `COLOR_0` is loaded into the models VBO (`color`, attribute 15; opaque white when absent)
 * @field losInfoTexCodes boolean Whether "los" mode decodes explicit level codes from the game's infoLOS shader (R level 0, 1/3, 2/3 or 1; G jam; B = 1 marker). `$info` then holds a legacy-compatible gray and `$info:losgrade` the decoded factors (r luminance mul, g saturation mul, b jam; r < 0.25 means not coded). Also visible to Lua shader definition files.
 */

/***
 * Engine specific information.
 *
 * @table Engine
 * @field version string "Major.Minor.PatchSet" for releases, "Major.Minor.PatchSet-CommitNum-gHash branch" otherwise
 * @field versionFull string "Major.Minor.PatchSet" for releases, "Major.Minor.PatchSet-CommitNum-gHash branch" otherwise. Will also include (buildFlags), if there're any.
 * @field versionMajor string Major part of the named release version
 * @field versionMinor string Minor part of the named release version
 * @field versionPatchSet string Build number of the named release version
 * @field commitsNumber string Number of commits after the latest named release, non-zero indicates a "dev" build
 * @field buildFlags string Gets additional engine buildflags, e.g. "Debug" or "Sync-Debug"
 * @field featureSupport FeatureSupport Table containing various engine features as keys; use for cross-version compat
 * @field wordSize integer Indicates the build type always 64 these days
 * @field gameSpeed integer Number of simulation gameframes per second
 * @field textColorCodes TextColorCode Table containing keys that represent the color code operations during font rendering
 */

bool LuaConstEngine::PushEntries(lua_State* L)
{
	LuaPushNamedString(L, "version"        , SpringVersion::GetSync()      );
	LuaPushNamedString(L, "versionFull"    , SpringVersion::GetFull()      );
	LuaPushNamedString(L, "versionMajor"   , SpringVersion::GetMajor()     );
	LuaPushNamedString(L, "versionMinor"   , SpringVersion::GetMinor()     );
	LuaPushNamedString(L, "versionPatchSet", SpringVersion::GetPatchSet()  );
	LuaPushNamedString(L, "commitsNumber"  , SpringVersion::GetCommits()   );
	LuaPushNamedString(L, "buildFlags"     , SpringVersion::GetAdditional());
	LuaPushNamedNumber(L, "wordSize", (!CLuaHandle::GetHandleSynced(L))? Platform::NativeWordSize() * 8: 0);

	LuaPushNamedNumber(L, "gameSpeed", GAME_SPEED);
	LuaPushNamedNumber(L, "maxCustomPaletteID", MAX_CUSTOM_COLORS - 1);

	// entries live in LuaFeatureSupport.h (shared with Lua shader definition files)
	lua_pushliteral(L, "FeatureSupport");
	lua_createtable(L, 0, 20);
		#define FS_BOOL(name, value)  LuaPushNamedBool(L, #name, value);
		#define FS_NUM(name, value)   LuaPushNamedNumber(L, #name, value);
		RECOIL_ENGINE_FEATURE_SUPPORT(FS_BOOL, FS_NUM, FS_NUM)
		#undef FS_BOOL
		#undef FS_NUM
	lua_rawset(L, -3);

	lua_pushliteral(L, "textColorCodes");
#ifndef HEADLESS
	bool newIndicators = fontHandler.disableOldColorIndicators;
#else
	bool newIndicators = true;
#endif
	lua_createtable(L, 0, 3);
		LuaPushNamedChar(L, "Color"          , static_cast<char>(newIndicators ? CglFont::ColorCodeIndicator : CglFont::OldColorCodeIndicator)  );
		LuaPushNamedChar(L, "ColorAndOutline", static_cast<char>(newIndicators ? CglFont::ColorCodeIndicatorEx : CglFont::OldColorCodeIndicatorEx));
		LuaPushNamedChar(L, "Reset"          , static_cast<char>(CglFont::ColorResetIndicator) );
	lua_rawset(L, -3);

	return true;
}

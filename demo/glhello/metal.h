/* macOS Metal Demo */

#pragma once

#ifdef __MACOS__

#include <ogl3d/ogl3d.hxx>
#include <gui/gui.hxx>

typedef struct _metal_t Metal;

Metal *metal_create(View *view, int *err);

void metal_destroy(Metal **metal);

void metal_draw(Metal *metal, real32_t angle, real32_t scale);

#endif // __MACOS__

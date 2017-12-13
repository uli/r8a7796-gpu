/*************************************************************************/ /*!
@File           rgxinit_vz_host.c
@Title          Device specific initialisation routines
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
@Description    Device specific functions
@License        Dual MIT/GPLv2

The contents of this file are subject to the MIT license as set out below.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

Alternatively, the contents of this file may be used under the terms of
the GNU General Public License Version 2 ("GPL") in which case the provisions
of GPL are applicable instead of those above.

If you wish to allow use of your version of this file only under the terms of
GPL, and not to allow others to use your version of this file under the terms
of the MIT license, indicate your decision by deleting the provisions above
and replace them with the notice and other provisions required by GPL as set
out in the file called "GPL-COPYING" included in this distribution. If you do
not delete the provisions above, a recipient may use your version of this file
under the terms of either the MIT license or GPL.

This License is also included in this distribution in the file called
"MIT-COPYING".

EXCEPT AS OTHERWISE STATED IN A NEGOTIATED AGREEMENT: (A) THE SOFTWARE IS
PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT; AND (B) IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/ /**************************************************************************/

#include <stddef.h>

#include "pvrsrv.h"
#include "physheap.h"
#include "rgxinit.h"
#include "allocmem.h"
#include "rgxutils.h"
#include "rgx_heaps.h"
#include "devicemem.h"
#include "rgxheapconfig.h"
#include "rgxfwutils_vz.h"
#include "rgxinit_vz.h"

PVRSRV_ERROR RGXVzInitHeaps(DEVICE_MEMORY_INFO *psNewMemoryInfo, 
							DEVMEM_HEAP_BLUEPRINT *psDeviceMemoryHeapCursor)
{
	IMG_UINT32 uiIdx;
	IMG_UINT32 uiStringLength = 32;
	PVRSRV_ERROR eError = PVRSRV_OK;

	/* Create additional OSIDs firmware heap */
	for (uiIdx=1; uiIdx < RGXFW_NUM_OS; uiIdx++)
	{
		psDeviceMemoryHeapCursor->pszName = OSAllocZMem(uiStringLength * sizeof(IMG_CHAR));
		if (psDeviceMemoryHeapCursor->pszName == NULL)
		{
			return PVRSRV_ERROR_OUT_OF_MEMORY;
		}

		OSSNPrintf((IMG_CHAR *)psDeviceMemoryHeapCursor->pszName, uiStringLength, "GuestFirmware%d", uiIdx);

		psDeviceMemoryHeapCursor->sHeapBaseAddr.uiAddr = 
				RGX_FIRMWARE_HEAP_BASE + (uiIdx * RGX_FIRMWARE_HEAP_SIZE);
		psDeviceMemoryHeapCursor->uiHeapLength = RGX_FIRMWARE_HEAP_SIZE;
		psDeviceMemoryHeapCursor->uiLog2DataPageSize = GET_LOG2_PAGESIZE();
	
		/* advance to the next heap */
		psDeviceMemoryHeapCursor++;
	}

	/* Re-set the heap count */
	psNewMemoryInfo->ui32HeapCount = (IMG_UINT32)(psDeviceMemoryHeapCursor - psNewMemoryInfo->psDeviceMemoryHeap);
	PVR_ASSERT(psNewMemoryInfo->ui32HeapCount <= RGX_MAX_HEAP_ID);

	/* Update the total default heap configuration count to include guest OSIDs firmware heaps;
	   for the firmware heap, accumulate all the guest OSIDs into heap configuration */
	psNewMemoryInfo->psDeviceMemoryHeapConfigArray[0].uiNumHeaps = psNewMemoryInfo->ui32HeapCount-1;
	psNewMemoryInfo->psDeviceMemoryHeapConfigArray[1].uiNumHeaps += (RGXFW_NUM_OS-1);

	return eError;
}

void RGXVzDeInitHeaps(DEVICE_MEMORY_INFO *psDevMemoryInfo)
{
	PVR_UNREFERENCED_PARAMETER(psDevMemoryInfo);
}

/******************************************************************************
 End of file (rgxinit_vz_host.c)
******************************************************************************/
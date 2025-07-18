/*
-----------------------------------------------------------------------
Copyright: 2010-2022, imec Vision Lab, University of Antwerp
           2014-2022, CWI, Amsterdam

Contact: astra@astra-toolbox.com
Website: http://www.astra-toolbox.com/

This file is part of the ASTRA Toolbox.


The ASTRA Toolbox is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

The ASTRA Toolbox is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with the ASTRA Toolbox. If not, see <http://www.gnu.org/licenses/>.

-----------------------------------------------------------------------
*/

#include "astra/cuda/gpu_runtime_wrapper.h"

#include "astra/cuda/2d/sirt.h"
#include "astra/cuda/2d/util.h"
#include "astra/cuda/2d/arith.h"

#include <cstdio>
#include <cassert>

namespace astraCUDA {

SIRT::SIRT() : ReconAlgo()
{
	D_projData = 0;
	D_tmpData = 0;

	D_lineWeight = 0;
	D_pixelWeight = 0;

	D_minMaskData = 0;
	D_maxMaskData = 0;

	fRelaxation = 1.0f;

	freeMinMaxMasks = false;
}


SIRT::~SIRT()
{
	reset();
}

void SIRT::reset()
{
	cudaFree(D_projData);
	cudaFree(D_tmpData);
	cudaFree(D_lineWeight);
	cudaFree(D_pixelWeight);
	if (freeMinMaxMasks) {
		cudaFree(D_minMaskData);
		cudaFree(D_maxMaskData);
	}

	D_projData = 0;
	D_tmpData = 0;

	D_lineWeight = 0;
	D_pixelWeight = 0;

	freeMinMaxMasks = false;
	D_minMaskData = 0;
	D_maxMaskData = 0;

	useVolumeMask = false;
	useSinogramMask = false;

	fRelaxation = 1.0f;

	ReconAlgo::reset();
}

bool SIRT::init()
{
	allocateVolumeData(D_pixelWeight, pixelPitch, dims);
	zeroVolumeData(D_pixelWeight, pixelPitch, dims);

	allocateVolumeData(D_tmpData, tmpPitch, dims);
	zeroVolumeData(D_tmpData, tmpPitch, dims);

	allocateProjectionData(D_projData, projPitch, dims);
	zeroProjectionData(D_projData, projPitch, dims);
	
	allocateProjectionData(D_lineWeight, linePitch, dims);
	zeroProjectionData(D_lineWeight, linePitch, dims);

	// We can't precompute lineWeights and pixelWeights when using a mask
	if (!useVolumeMask && !useSinogramMask)
		precomputeWeights();

	// TODO: check if allocations succeeded
	return true;
}

bool SIRT::precomputeWeights()
{
	zeroProjectionData(D_lineWeight, linePitch, dims);
	if (useVolumeMask) {
		callFP(D_maskData, maskPitch, D_lineWeight, linePitch, 1.0f);
	} else {
		processVol<opSet>(D_tmpData, 1.0f, tmpPitch, dims);
		callFP(D_tmpData, tmpPitch, D_lineWeight, linePitch, 1.0f);
	}
	processSino<opInvert>(D_lineWeight, linePitch, dims);

	if (useSinogramMask) {
		// scale line weights with sinogram mask to zero out masked sinogram pixels
		processSino<opMul>(D_lineWeight, D_smaskData, linePitch, dims);
	}


	zeroVolumeData(D_pixelWeight, pixelPitch, dims);
	if (useSinogramMask) {
		callBP(D_pixelWeight, pixelPitch, D_smaskData, smaskPitch, 1.0f);
	} else {
		processSino<opSet>(D_projData, 1.0f, projPitch, dims);
		callBP(D_pixelWeight, pixelPitch, D_projData, projPitch, 1.0f);
	}
	processVol<opInvert>(D_pixelWeight, pixelPitch, dims);

	if (useVolumeMask) {
		// scale pixel weights with mask to zero out masked pixels
		processVol<opMul>(D_pixelWeight, D_maskData, pixelPitch, dims);
	}

	// Also fold the relaxation factor into pixel weights
	processVol<opMul>(D_pixelWeight, fRelaxation, pixelPitch, dims);

	return true;
}

bool SIRT::doSlabCorrections()
{
	// This function compensates for effectively infinitely large slab-like
	// objects of finite thickness 1 in a parallel beam geometry.

	// Each ray through the object has an intersection of length d/cos(alpha).
	// The length of the ray actually intersecting the reconstruction volume is
	// given by D_lineWeight. By dividing by 1/cos(alpha) and multiplying by the
	// lineweights, we correct for this missing attenuation outside of the
	// reconstruction volume, assuming the object is homogeneous.

	// This effectively scales the output values by assuming the thickness d
	// is 1 unit.


	// This function in its current implementation only works if there are no masks.
	// In this case, init() will also have already called precomputeWeights(),
	// so we can use D_lineWeight.
	if (useVolumeMask || useSinogramMask)
		return false;

	// Parallel-beam only
	if (!parProjs)
		return false;

	// multiply by line weights
	processSino<opDiv>(D_sinoData, D_lineWeight, projPitch, dims);

	SDimensions subdims = dims;
	subdims.iProjAngles = 1;

	// divide by 1/cos(angle)
	// ...but limit the correction to -80/+80 degrees.
	float bound = cosf(1.3963f);
	float* t = (float*)D_sinoData;
	for (int i = 0; i < dims.iProjAngles; ++i) {
		float angle, detsize, offset;
		getParParameters(parProjs[i], dims.iProjDets, angle, detsize, offset);
		float f = fabs(cosf(angle));

		if (f < bound)
			f = bound;

		processSino<opMul>(t, f, sinoPitch, subdims);
		t += sinoPitch;
	}
	return true;
}


bool SIRT::setMinMaxMasks(float* D_minMaskData_, float* D_maxMaskData_,
	                      unsigned int iPitch)
{
	D_minMaskData = D_minMaskData_;
	D_maxMaskData = D_maxMaskData_;
	minMaskPitch = iPitch;
	maxMaskPitch = iPitch;

	freeMinMaxMasks = false;
	return true;
}

bool SIRT::uploadMinMaxMasks(const float* pfMinMaskData, const float* pfMaxMaskData,
	                         unsigned int iPitch)
{
	freeMinMaxMasks = true;
	bool ok = true;
	if (pfMinMaskData) {
		allocateVolumeData(D_minMaskData, minMaskPitch, dims);
		ok = copyVolumeToDevice(pfMinMaskData, iPitch,
		                        dims,
		                        D_minMaskData, minMaskPitch);
	}
	if (!ok)
		return false;

	if (pfMaxMaskData) {
		allocateVolumeData(D_maxMaskData, maxMaskPitch, dims);
		ok = copyVolumeToDevice(pfMaxMaskData, iPitch,
		                        dims,
		                        D_maxMaskData, maxMaskPitch);
	}
	if (!ok)
		return false;

	return true;
}

bool SIRT::iterate(unsigned int iterations)
{
	if (useVolumeMask || useSinogramMask)
		precomputeWeights();

	// iteration
	for (unsigned int iter = 0; iter < iterations && !astra::shouldAbort(); ++iter) {

		// copy sinogram to projection data
		duplicateProjectionData(D_projData, D_sinoData, projPitch, dims);

		// do FP, subtracting projection from sinogram
		if (useVolumeMask) {
				duplicateVolumeData(D_tmpData, D_volumeData, volumePitch, dims);
				processVol<opMul>(D_tmpData, D_maskData, tmpPitch, dims);
				callFP(D_tmpData, tmpPitch, D_projData, projPitch, -1.0f);
		} else {
				callFP(D_volumeData, volumePitch, D_projData, projPitch, -1.0f);
		}

		processSino<opMul>(D_projData, D_lineWeight, projPitch, dims);

		zeroVolumeData(D_tmpData, tmpPitch, dims);

		callBP(D_tmpData, tmpPitch, D_projData, projPitch, 1.0f);

		// pixel weights also contain the volume mask and relaxation factor
		processVol<opAddMul>(D_volumeData, D_pixelWeight, D_tmpData, volumePitch, dims);

		if (useMinConstraint)
			processVol<opClampMin>(D_volumeData, fMinConstraint, volumePitch, dims);
		if (useMaxConstraint)
			processVol<opClampMax>(D_volumeData, fMaxConstraint, volumePitch, dims);
		if (D_minMaskData)
			processVol<opClampMinMask>(D_volumeData, D_minMaskData, volumePitch, dims);
		if (D_maxMaskData)
			processVol<opClampMaxMask>(D_volumeData, D_maxMaskData, volumePitch, dims);
	}

	return true;
}

float SIRT::computeDiffNorm()
{
	// copy sinogram to projection data
	duplicateProjectionData(D_projData, D_sinoData, projPitch, dims);

	// do FP, subtracting projection from sinogram
	if (useVolumeMask) {
			duplicateVolumeData(D_tmpData, D_volumeData, volumePitch, dims);
			processVol<opMul>(D_tmpData, D_maskData, tmpPitch, dims);
			callFP(D_tmpData, tmpPitch, D_projData, projPitch, -1.0f);
	} else {
			callFP(D_volumeData, volumePitch, D_projData, projPitch, -1.0f);
	}


	// compute norm of D_projData

	float s = dotProduct2D(D_projData, projPitch, dims.iProjDets, dims.iProjAngles);

	return sqrt(s);
}


}

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

#include "astra/cuda/3d/util3d.h"
#include "astra/cuda/3d/dims3d.h"
#include "astra/cuda/3d/arith3d.h"
#include "astra/cuda/3d/cone_bp.h"

#include "astra/cuda/2d/fft.h"

#include "astra/Logging.h"

#include <cstdio>
#include <cassert>
#include <vector>

namespace astraCUDA3d {

static const unsigned int g_anglesPerWeightBlock = 16;
static const unsigned int g_detBlockU = 32;
static const unsigned int g_detBlockV = 32;

static const unsigned g_MaxAngles = 12000;

__constant__ float gC_angle[g_MaxAngles];

bool checkCufft(cufftResult err, const char *msg)
{
	if (err != CUFFT_SUCCESS) {
		ASTRA_ERROR("%s: CUFFT error %d.", msg, err);
		return false;
	} else {
		return true;
	}
}



// TODO: To support non-cube voxels, preweighting needs per-view
// parameters. NB: Need to properly take into account the
// anisotropic volume normalization done for that too.


__global__ void devFDK_preweight(void* D_projData, unsigned int projPitch, unsigned int startAngle, unsigned int endAngle, float fSrcOrigin, float fDetOrigin, float fZShift, float fDetUSize, float fDetVSize, const SDimensions3D dims)
{
	float* projData = (float*)D_projData;
	int angle = startAngle + blockIdx.y * g_anglesPerWeightBlock + threadIdx.y;
	if (angle >= endAngle)
		return;

	const int detectorU = (blockIdx.x%((dims.iProjU+g_detBlockU-1)/g_detBlockU)) * g_detBlockU + threadIdx.x;
	const int startDetectorV = (blockIdx.x/((dims.iProjU+g_detBlockU-1)/g_detBlockU)) * g_detBlockV;
	int endDetectorV = startDetectorV + g_detBlockV;
	if (endDetectorV > dims.iProjV)
		endDetectorV = dims.iProjV;

	// We need the length of the central ray and the length of the ray(s) to
	// our detector pixel(s).

	const float fCentralRayLength = fSrcOrigin + fDetOrigin;

	const float fU = (detectorU - 0.5f*dims.iProjU + 0.5f) * fDetUSize;

	const float fT = fCentralRayLength * fCentralRayLength + fU * fU;

	float fV = (startDetectorV - 0.5f*dims.iProjV + 0.5f) * fDetVSize + fZShift;

	// Contributions to the weighting factors:
	// fCentralRayLength / fRayLength   : the main FDK preweighting factor
	// fSrcOrigin / (fDetUSize * fCentralRayLength)
	//                                  : to adjust the filter to the det width
	// pi / (2 * iProjAngles)           : scaling of the integral over angles

	const float fW2 = fCentralRayLength / (fDetUSize * fSrcOrigin);
	const float fW = fCentralRayLength * fW2 * (M_PI / 2.0f) / (float)dims.iProjAngles;

	for (int detectorV = startDetectorV; detectorV < endDetectorV; ++detectorV)
	{
		const float fRayLength = sqrtf(fT + fV * fV);

		const float fWeight = fW / fRayLength;

		projData[(detectorV*dims.iProjAngles+angle)*projPitch+detectorU] *= fWeight;

		fV += fDetVSize;
	}
}

__global__ void devFDK_ParkerWeight(void* D_projData, unsigned int projPitch, unsigned int startAngle, unsigned int endAngle, float fSrcOrigin, float fDetOrigin, float fDetUSize, float fCentralFanAngle, float fScale, const SDimensions3D dims)
{
	float* projData = (float*)D_projData;
	int angle = startAngle + blockIdx.y * g_anglesPerWeightBlock + threadIdx.y;
	if (angle >= endAngle)
		return;

	const int detectorU = (blockIdx.x%((dims.iProjU+g_detBlockU-1)/g_detBlockU)) * g_detBlockU + threadIdx.x;
	const int startDetectorV = (blockIdx.x/((dims.iProjU+g_detBlockU-1)/g_detBlockU)) * g_detBlockV;
	int endDetectorV = startDetectorV + g_detBlockV;
	if (endDetectorV > dims.iProjV)
		endDetectorV = dims.iProjV;

	// We need the length of the central ray and the length of the projection
	// of our ray onto the central slice

	const float fCentralRayLength = fSrcOrigin + fDetOrigin;

	// TODO: Detector pixel size
	const float fU = (detectorU - 0.5f*dims.iProjU + 0.5f) * fDetUSize;

	const float fGamma = atanf(fU / fCentralRayLength);
	float fBeta = gC_angle[angle];

	// compute the weight depending on the location in the central fan's radon
	// space
	float fWeight;

	if (fBeta <= 0.0f) {
		fWeight = 0.0f;
	} else if (fBeta <= 2.0f*(fCentralFanAngle + fGamma)) {
		fWeight = sinf((M_PI / 4.0f) * fBeta / (fCentralFanAngle + fGamma));
		fWeight *= fWeight;
	} else if (fBeta <= M_PI + 2*fGamma) {
		fWeight = 1.0f;
	} else if (fBeta <= M_PI + 2*fCentralFanAngle) {
		fWeight = sinf((M_PI / 4.0f) * (M_PI + 2.0f*fCentralFanAngle - fBeta) / (fCentralFanAngle - fGamma));
		fWeight *= fWeight;
	} else {
		fWeight = 0.0f;
	}

	fWeight *= fScale;

	for (int detectorV = startDetectorV; detectorV < endDetectorV; ++detectorV)
	{
		projData[(detectorV*dims.iProjAngles+angle)*projPitch+detectorU] *= fWeight;
	}
}



// Perform the FDK pre-weighting and filtering
bool FDK_PreWeight(cudaPitchedPtr D_projData,
                float fSrcOrigin, float fDetOrigin,
                float fZShift,
                float fDetUSize, float fDetVSize,
                bool bShortScan,
                const SDimensions3D& dims, const float* angles)
{
	// The pre-weighting factor for a ray is the cosine of the angle between
	// the central line and the ray.

	cudaStream_t stream;
	if (!checkCuda(cudaStreamCreate(&stream), "FDK_PreWeight stream"))
		return false;

	dim3 dimBlock(g_detBlockU, g_anglesPerWeightBlock);
	dim3 dimGrid( ((dims.iProjU+g_detBlockU-1)/g_detBlockU)*((dims.iProjV+g_detBlockV-1)/g_detBlockV),
	              (dims.iProjAngles+g_anglesPerWeightBlock-1)/g_anglesPerWeightBlock);

	int projPitch = D_projData.pitch/sizeof(float);

	devFDK_preweight<<<dimGrid, dimBlock, 0, stream>>>(D_projData.ptr, projPitch, 0, dims.iProjAngles, fSrcOrigin, fDetOrigin, fZShift, fDetUSize, fDetVSize, dims);

	if (bShortScan && dims.iProjAngles > 1) {
		ASTRA_DEBUG("Doing Parker weighting");
		// We do short-scan Parker weighting

		// First, determine (in a very basic way) the interval that's
		// been scanned. We assume angles[0] is one of the endpoints of the
		// range.
		float fdA = angles[1] - angles[0];

		while (fdA < -M_PI)
			fdA += 2*M_PI;
		while (fdA >= M_PI)
			fdA -= 2*M_PI;

		float fAngleBase;
		if (fdA >= 0.0f) {
			// going up from angles[0]
			fAngleBase = angles[0];
			ASTRA_DEBUG("Second angle >= first angle, so assuming angles are incrementing");
		} else {
			// going down from angles[0]
			fAngleBase = angles[dims.iProjAngles - 1];
			ASTRA_DEBUG("Second angle < first angle, so assuming angles are decrementing");
		}

		// We pick the lowest end of the range, and then
		// move all angles so they fall in [0,2pi)

		std::vector<float> fRelAngles(dims.iProjAngles);
		for (unsigned int i = 0; i < dims.iProjAngles; ++i) {
			float f = angles[i] - fAngleBase;
			while (f >= 2*M_PI)
				f -= 2*M_PI;
			while (f < 0)
				f += 2*M_PI;
			fRelAngles[i] = f;
		}

		float fRange = fabs(fRelAngles[dims.iProjAngles-1] - fRelAngles[0]);
		// Adjust for discretisation
		fRange /= dims.iProjAngles - 1;
		fRange *= dims.iProjAngles;

		ASTRA_DEBUG("Assuming angles are linearly ordered and equally spaced for Parker weighting. Angular range %f radians", fRange);
		float fScale = fRange / M_PI;

		bool ok = true;
		ok &= checkCuda(cudaMemcpyToSymbolAsync(gC_angle, &fRelAngles[0],
		                                        dims.iProjAngles*sizeof(float), 0,
		                                        cudaMemcpyHostToDevice, stream),
		                "FDK_PreWeight transfer");
		ok &= checkCuda(cudaStreamSynchronize(stream), "FDK_PreWeight");
		if (!ok) {
			cudaStreamDestroy(stream);
			return false;
		}

		float fCentralFanAngle = fabs(atanf(fDetUSize * (dims.iProjU*0.5f) /
		                               (fSrcOrigin + fDetOrigin)));

		if (fRange + 1e-3 < M_PI + 2*fCentralFanAngle) {
			ASTRA_WARN("Angular range (%f rad) smaller than Parker weighting range (%f rad)", fRange, M_PI + 2*fCentralFanAngle);
		}

		devFDK_ParkerWeight<<<dimGrid, dimBlock, 0, stream>>>(D_projData.ptr, projPitch, 0, dims.iProjAngles, fSrcOrigin, fDetOrigin, fDetUSize, fCentralFanAngle, fScale, dims);
	}
	if (!checkCuda(cudaStreamSynchronize(stream), "FDK_PreWeight")) {
		cudaStreamDestroy(stream);
		return false;
	}

	cudaStreamDestroy(stream);

	return true;
}

bool FDK_Filter(cudaPitchedPtr D_projData,
                const astra::SFilterConfig &filterConfig,
                const SDimensions3D& dims)
{
	cudaStream_t stream;
	if (!checkCuda(cudaStreamCreate(&stream), "FDK_Filter stream"))
		return false;

	bool singleFilter;
	cufftComplex *D_filter;

	bool ok = astraCUDA::prepareCuFFTFilter(filterConfig, D_filter, singleFilter, dims.iProjAngles, dims.iProjU, stream);

	if (!ok) {
		if (D_filter)
			astraCUDA::freeComplexOnDevice(D_filter);
		cudaStreamDestroy(stream);
		return false;
	}

	if (!D_filter) {
		// For FILTER_NONE
		cudaStreamDestroy(stream);
		return true;
	}

	int iPaddedDetCount = calcNextPowerOfTwo(2 * dims.iProjU);
	int iHalfFFTSize = astra::calcFFTFourierSize(iPaddedDetCount);

	cufftHandle planF;
	cufftHandle planI;

	if (!checkCufft(cufftPlan1d(&planF, iPaddedDetCount, CUFFT_R2C, dims.iProjAngles), "FDK filter FFT plan")) {
		cudaStreamDestroy(stream);
		astraCUDA::freeComplexOnDevice(D_filter);
		return false;
	}
	if (!checkCufft(cufftSetStream(planF, stream), "FDK filter FFT plan stream")) {
		cudaStreamDestroy(stream);
		astraCUDA::freeComplexOnDevice(D_filter);
		return false;
	}

	if (!checkCufft(cufftPlan1d(&planI, iPaddedDetCount, CUFFT_C2R, dims.iProjAngles), "FDK filter IFFT plan")) {
		cudaStreamDestroy(stream);
		astraCUDA::freeComplexOnDevice(D_filter);
		cufftDestroy(planF);
		return false;
	}
	if (!checkCufft(cufftSetStream(planI, stream), "FDK filter IFFT plan stream")) {
		cudaStreamDestroy(stream);
		astraCUDA::freeComplexOnDevice(D_filter);
		cufftDestroy(planF);
		cufftDestroy(planI);
		return false;
	}

	int projPitch = D_projData.pitch/sizeof(float);


	// We process one sinogram at a time.
	float* D_sinoData = (float*)D_projData.ptr;

	cufftComplex * D_pcSinoFFT = NULL;

	if (!astraCUDA::allocateComplexOnDevice(dims.iProjAngles, iHalfFFTSize, &D_pcSinoFFT)) {
		cudaStreamDestroy(stream);
		astraCUDA::freeComplexOnDevice(D_filter);
		cufftDestroy(planF);
		cufftDestroy(planI);
		return false;
	}

	float * D_pfPadded = NULL;
	size_t bufferMemSize = sizeof(float) * dims.iProjAngles * iPaddedDetCount;
	if (!checkCuda(cudaMalloc((void **)&D_pfPadded, bufferMemSize), "FDK filter malloc")) {
		cudaStreamDestroy(stream);
		astraCUDA::freeComplexOnDevice(D_pcSinoFFT);
		astraCUDA::freeComplexOnDevice(D_filter);
		cufftDestroy(planF);
		cufftDestroy(planI);
		return false;
	}

	ok = true;
	for (int v = 0; v < dims.iProjV; ++v) {
		if (!checkCuda(cudaMemsetAsync(D_pfPadded, 0, bufferMemSize, stream), "FDK filter memset")) {
			ok = false;
			break;
		}

		// pitched memcpy 2D to handle both source pitch and target padding
		if (!checkCuda(cudaMemcpy2DAsync(D_pfPadded, iPaddedDetCount*sizeof(float), D_sinoData, projPitch*sizeof(float), dims.iProjU*sizeof(float), dims.iProjAngles, cudaMemcpyDeviceToDevice, stream), "FDK filter memcpy")) {
			ok = false;
			break;
		}

		if (!checkCufft(cufftExecR2C(planF, (cufftReal *)D_pfPadded, D_pcSinoFFT), "FDK filter forward exec")) {
			ok = false;
			break;
		}

		if (!astraCUDA::applyFilter(dims.iProjAngles, iHalfFFTSize, D_pcSinoFFT, D_filter, singleFilter, stream)) {
			ok = false;
			break;
		}

		// Getting rid of the const qualifier is due to cufft API issue?
		if (!checkCufft(cufftExecC2R(planI, (cufftComplex *)D_pcSinoFFT,
	                      (cufftReal *)D_pfPadded), "FDK filter inverse exec"))
		{
			ok = false;
			break;
		}

		if (!astraCUDA::rescaleInverseFourier(dims.iProjAngles, iPaddedDetCount, D_pfPadded, stream)) {
			ok = false;
			break;
		}

		if (!checkCuda(cudaMemsetAsync(D_sinoData, 0, sizeof(float) * dims.iProjAngles * projPitch, stream), "FDK filter memset")) {
			ok = false;
			break;
		}

		// pitched memcpy 2D to handle both source padding and target pitch
		if (!checkCuda(cudaMemcpy2DAsync(D_sinoData, projPitch*sizeof(float), D_pfPadded, iPaddedDetCount*sizeof(float), dims.iProjU*sizeof(float), dims.iProjAngles, cudaMemcpyDeviceToDevice, stream), "FDK filter memcpy")) {
			ok = false;
			break;
		}

		D_sinoData += (dims.iProjAngles * projPitch);
	}

	ok &= checkCuda(cudaStreamSynchronize(stream), "FDK filter sync");

	cufftDestroy(planF);
	cufftDestroy(planI);

	cudaFree(D_pfPadded);
	astraCUDA::freeComplexOnDevice(D_pcSinoFFT);
	astraCUDA::freeComplexOnDevice(D_filter);

	cudaStreamDestroy(stream);

	return ok;
}


bool FDK(cudaPitchedPtr D_volumeData,
         cudaPitchedPtr D_projData,
         const SConeProjection* angles,
         const SDimensions3D& dims, SProjectorParams3D params, bool bShortScan,
         const astra::SFilterConfig &filterConfig)
{
	bool ok;

	// NB: We don't support arbitrary cone_vec geometries here.
	// Only those that are vertical sub-geometries
	// (cf. CompositeGeometryManager) of regular cone geometries.
	assert(dims.iProjAngles > 0);
	const SConeProjection& p0 = angles[0];

	// assuming U is in the XY plane, V is parallel to Z axis
	float fDetCX = p0.fDetSX + 0.5*dims.iProjU*p0.fDetUX;
	float fDetCY = p0.fDetSY + 0.5*dims.iProjU*p0.fDetUY;
	float fDetCZ = p0.fDetSZ + 0.5*dims.iProjV*p0.fDetVZ;

	float fSrcOrigin = sqrt(p0.fSrcX*p0.fSrcX + p0.fSrcY*p0.fSrcY);
	float fDetOrigin = sqrt(fDetCX*fDetCX + fDetCY*fDetCY);
	float fDetUSize = sqrt(p0.fDetUX*p0.fDetUX + p0.fDetUY*p0.fDetUY);
	float fDetVSize = abs(p0.fDetVZ);

	float fZShift = fDetCZ - p0.fSrcZ;

	float *pfAngles = new float[dims.iProjAngles];
	for (unsigned int i = 0; i < dims.iProjAngles; ++i) {
		// FIXME: Sign/order
		pfAngles[i] = -atan2(angles[i].fSrcX, angles[i].fSrcY) + M_PI;
	}


#if 1
	ok = FDK_PreWeight(D_projData, fSrcOrigin, fDetOrigin,
	                fZShift, fDetUSize, fDetVSize,
	                bShortScan, dims, pfAngles);
#else
	ok = true;
#endif
	delete[] pfAngles;

	if (!ok)
		return false;

#if 1
	// Perform filtering
	ok = FDK_Filter(D_projData, filterConfig, dims);
#endif

	if (!ok)
		return false;

	// Perform BP
	assert(params.projKernel == ker3d_fdk_weighting);

	//ok = FDK_BP(D_volumeData, D_projData, fSrcOrigin, fDetOrigin, 0.0f, 0.0f, fDetUSize, fDetVSize, dims, pfAngles);
	ok = ConeBP(D_volumeData, D_projData, dims, angles, params);

	if (!ok)
		return false;

	return true;
}


}

//
// Created by ss on 16-12-14.
//

#include <cfloat>
#include <sys/time.h>
#include <thrust/sort.h>
#include <cuda_runtime.h>
#include <thrust/device_ptr.h>
#include "multiSmoSolver.h"
#include "trainClassifier.h"
#include "../svm-shared/constant.h"
#include "../svm-shared/smoGPUHelper.h"
#include "../svm-shared/HessianIO/deviceHessianOnFly.h"
#include "../svm-shared/Cache/subHessianCalculator.h"
#include "../SharedUtility/getMin.h"
#include "../SharedUtility/Timer.h"
#include "../SharedUtility/powerOfTwo.h"
#include "../SharedUtility/CudaMacro.h"
#include "multiPredictor.h"

void MultiSmoSolver::solve() {
    int nrClass = problem.getNumOfClasses();

    if (model.vC.size() == 0) {//initialize C for all the binary classes
        model.vC = vector<real>(nrClass * (nrClass - 1) / 2, param.C);
    }

    //train nrClass*(nrClass-1)/2 binary models
    int k = 0;
    vector<int> prob_start(problem.start);
	
	std::map<int , int>indexMap;
	indexMap.clear();
    
    for (int i = 0; i < nrClass; ++i) {
        int ci = problem.count[i];
        for (int j = i + 1; j < nrClass; ++j) {
            printf("training classifier with label %d and %d\n", i, j);
            SvmProblem subProblem = problem.getSubProblem(i, j);

            //determine the size of working set
            workingSetSize = 1024;
            int minSize = min(subProblem.count[0], subProblem.count[1]);
            if (minSize< workingSetSize) {
                workingSetSize = floorPow2(minSize);
            }
            q = workingSetSize / 2;
            printf("q = %d, working set size = %d\n", q, workingSetSize);

            //should be called after workingSetSize is initialized
            init4Training(subProblem);

            //convert binary sub-problem to csr matrix and copy it to device
            CSRMatrix subProblemMat(subProblem.v_vSamples, subProblem.getNumOfFeatures());
            subProblemMat.copy2Dev(devVal, devRowPtr, devColInd, devSelfDot);
            nnz = subProblemMat.getNnz();

            printf("#positive ins %d, #negative ins %d\n", subProblem.count[0], subProblem.count[1]);
            int totalIter = 0;
            TIMER_START(trainingTimer)
            //start binary svm training
            for (int l = 0;; ++l) {
                workingSetIndicator = vector<int>(subProblem.getNumOfSamples(), 0);
                if (l == 0) {
                    selectWorkingSetAndPreCompute(subProblem, workingSetSize / 2, model.vC[k]);
                } else {
                    for (int m = 0; m < workingSetSize - q; ++m) {
                        workingSetIndicator[workingSet[q + m]] = 1;
                    }
                    selectWorkingSetAndPreCompute(subProblem, q / 2, model.vC[k]);
                }
                TIMER_START(iterationTimer)
                localSMO << < 1, workingSetSize, workingSetSize * sizeof(float) * 3 + 2 * sizeof(float) >> >
                                                 (devLabel, devYiGValue, devAlpha, devAlphaDiff, devWorkingSet, workingSetSize, model.vC[k], devHessianMatrixCache, subProblem.getNumOfSamples());
                TIMER_STOP(iterationTimer)
                TIMER_START(updateGTimer)
                updateF << < gridSize, BLOCK_SIZE >> >
                                       (devYiGValue, devLabel, devWorkingSet, workingSetSize, devAlphaDiff, devHessianMatrixCache, subProblem.getNumOfSamples());
                TIMER_STOP(updateGTimer)
                float diff;
                checkCudaErrors(cudaMemcpyFromSymbol(&diff, devDiff, sizeof(real), 0, cudaMemcpyDeviceToHost));
                if (l % 10 == 0)
                    printf(".");
                cout.flush();
                if (diff < EPS) {
                    printf("\nup + low = %f\n", diff);
                    break;
                }
            }
            TIMER_STOP(trainingTimer)
            printf("obj = %f\n", getObjValue(subProblem.getNumOfSamples()));
            subProblemMat.freeDev(devVal, devRowPtr, devColInd, devSelfDot);
            vector<int> svIndex;
            vector<real> coef;
            real rho;


            extractModel(subProblem, svIndex, coef, rho);
            model.getModelParam(subProblem, svIndex, coef, prob_start, ci, i, j);
            model.addBinaryModel(subProblem, svIndex, coef, rho, i, j, indexMap);
            k++;

            deinit4Training();
        }
    }


}

void MultiSmoSolver::init4Training(const SvmProblem &subProblem) {
    unsigned int trainingSize = subProblem.getNumOfSamples();

    workingSet = vector<int>(workingSetSize);
    checkCudaErrors(cudaMalloc((void **) &devAlphaDiff, sizeof(real) * workingSetSize));
    checkCudaErrors(cudaMalloc((void **) &devWorkingSet, sizeof(int) * workingSetSize));

    checkCudaErrors(cudaMalloc((void **) &devAlpha, sizeof(real) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devYiGValue, sizeof(real) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devLabel, sizeof(int) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devWorkingSetIndicator, sizeof(int) * trainingSize));

    checkCudaErrors(cudaMemset(devAlpha, 0, sizeof(real) * trainingSize));
    vector<real> negatedLabel(trainingSize);
    for (int i = 0; i < trainingSize; ++i) {
        negatedLabel[i] = -subProblem.v_nLabels[i];
    }
    checkCudaErrors(cudaMemcpy(devYiGValue, negatedLabel.data(), sizeof(real) * trainingSize,
                               cudaMemcpyHostToDevice));
    checkCudaErrors(
            cudaMemcpy(devLabel, subProblem.v_nLabels.data(), sizeof(int) * trainingSize, cudaMemcpyHostToDevice));

    InitSolver(trainingSize);//initialise base solver

    checkCudaErrors(cudaMalloc((void **) &devHessianMatrixCache, sizeof(real) * workingSetSize * trainingSize));

    for (int j = 0; j < trainingSize; ++j) {
        hessianDiag[j] = 1;//assume using RBF kernel
    }
    checkCudaErrors(
            cudaMemcpy(devHessianDiag, hessianDiag, sizeof(real) * trainingSize, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMalloc((void **) &devFValue4Sort, sizeof(real) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devIdx4Sort, sizeof(int) * trainingSize));

}

void MultiSmoSolver::deinit4Training() {
    checkCudaErrors(cudaFree(devAlphaDiff));
    checkCudaErrors(cudaFree(devWorkingSet));

    checkCudaErrors(cudaFree(devAlpha));
    checkCudaErrors(cudaFree(devYiGValue));
    checkCudaErrors(cudaFree(devLabel));
    checkCudaErrors(cudaFree(devWorkingSetIndicator));

    DeInitSolver();

    checkCudaErrors(cudaFree(devHessianMatrixCache));
    checkCudaErrors(cudaFree(devFValue4Sort));
    checkCudaErrors(cudaFree(devIdx4Sort));
}

void MultiSmoSolver::extractModel(const SvmProblem &subProblem, vector<int> &svIndex, vector<real> &coef,
                                  real &rho) const {
    const unsigned int trainingSize = subProblem.getNumOfSamples();
    vector<real> alpha(trainingSize);
    const vector<int> &label = subProblem.v_nLabels;
    checkCudaErrors(cudaMemcpy(alpha.data(), devAlpha, sizeof(real) * trainingSize, cudaMemcpyDeviceToHost));
    for (int i = 0; i < trainingSize; ++i) {
        if (alpha[i] != 0) {
            coef.push_back(label[i] * alpha[i]);
            svIndex.push_back(i);

        }
    }
    checkCudaErrors(cudaMemcpyFromSymbol(&rho, devRho, sizeof(real), 0, cudaMemcpyDeviceToHost));
    printf("# of SV %lu\nbias = %f\n", svIndex.size(), rho);
}

MultiSmoSolver::MultiSmoSolver(const SvmProblem &problem, SvmModel &model, const SVMParam &param) :
        problem(problem), model(model), param(param) {
}

MultiSmoSolver::~MultiSmoSolver() {
}

void
MultiSmoSolver::selectWorkingSetAndPreCompute(const SvmProblem &subProblem, uint numOfSelectPairs, real penaltyC) {
    uint numOfSamples = subProblem.getNumOfSamples();
    uint oldSize = workingSetSize / 2 - numOfSelectPairs;
    TIMER_START(selectTimer)
    thrust::device_ptr<float> valuePointer = thrust::device_pointer_cast(devFValue4Sort);
    thrust::device_ptr<int> indexPointer = thrust::device_pointer_cast(devIdx4Sort);
    vector<int> oldWorkingSet = workingSet;

    checkCudaErrors(cudaMemcpy(devWorkingSetIndicator, workingSetIndicator.data(), sizeof(int) * numOfSamples,
                               cudaMemcpyHostToDevice));

    //get q most violation pairs
    getFUpValues << < gridSize, BLOCK_SIZE >> >
                                (devYiGValue, devAlpha, devLabel, numOfSamples, penaltyC, devFValue4Sort, devIdx4Sort, devWorkingSetIndicator);
    thrust::sort_by_key(valuePointer, valuePointer + numOfSamples, indexPointer, thrust::greater<float>());
    checkCudaErrors(cudaMemcpy(workingSet.data() + oldSize * 2, devIdx4Sort, sizeof(int) * numOfSelectPairs,
                               cudaMemcpyDeviceToHost));
    for (int i = 0; i < numOfSelectPairs; ++i) {
        workingSetIndicator[workingSet[oldSize * 2 + i]] = 1;
    }
    checkCudaErrors(cudaMemcpy(devWorkingSetIndicator, workingSetIndicator.data(), sizeof(int) * numOfSamples,
                               cudaMemcpyHostToDevice));
    getFLowValues << < gridSize, BLOCK_SIZE >> >
                                 (devYiGValue, devAlpha, devLabel, numOfSamples, penaltyC, devFValue4Sort, devIdx4Sort, devWorkingSetIndicator);
    thrust::sort_by_key(valuePointer, valuePointer + numOfSamples, indexPointer, thrust::greater<float>());
    checkCudaErrors(
            cudaMemcpy(workingSet.data() + oldSize * 2 + numOfSelectPairs, devIdx4Sort, sizeof(int) * numOfSelectPairs,
                       cudaMemcpyDeviceToHost));

    //get pairs from last working set
    for (int i = 0; i < oldSize * 2; ++i) {
        workingSet[i] = oldWorkingSet[numOfSelectPairs * 2 + i];
    }
    checkCudaErrors(cudaMemcpy(devWorkingSet, workingSet.data(), sizeof(int) * workingSetSize, cudaMemcpyHostToDevice));
    TIMER_STOP(selectTimer)

    //move old kernel values to get space
    checkCudaErrors(cudaMemcpy(devHessianMatrixCache,
                               devHessianMatrixCache + numOfSamples * numOfSelectPairs * 2,
                               sizeof(real) * numOfSamples * oldSize * 2,
                               cudaMemcpyDeviceToDevice));
    vector<vector<KeyValue> > computeSamples;
    for (int i = 0; i < numOfSelectPairs * 2; ++i) {
        computeSamples.push_back(subProblem.v_vSamples[workingSet[oldSize * 2 + i]]);
    }
    TIMER_START(preComputeTimer)
    //preCompute kernel values of new selected instances
    cusparseHandle_t handle;
    cusparseMatDescr_t descr;
    CSRMatrix workingSetMat(computeSamples, subProblem.getNumOfFeatures());
    real * devWSVal;
    int *devWSColInd;
    int *devWSRowPtr;
    real * devWSSelfDot;
    workingSetMat.copy2Dev(devWSVal, devWSRowPtr, devWSColInd, devWSSelfDot);
    SubHessianCalculator::prepareCSRContext(handle, descr);
    CSRMatrix::CSRmm2Dense(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, CUSPARSE_OPERATION_TRANSPOSE, numOfSelectPairs * 2,
                           numOfSamples, subProblem.getNumOfFeatures(), descr,
                           workingSetMat.getNnz(), devWSVal, devWSRowPtr, devWSColInd, descr, nnz, devVal, devRowPtr,
                           devColInd, devHessianMatrixCache + numOfSamples * oldSize * 2);
    RBFKernel << < Ceil(numOfSelectPairs * 2 * numOfSamples, BLOCK_SIZE), BLOCK_SIZE >> > (devWSSelfDot, devSelfDot,
            devHessianMatrixCache + numOfSamples * oldSize * 2, numOfSelectPairs * 2, numOfSamples, param.gamma);
    SubHessianCalculator::releaseCSRContext(handle, descr);
    workingSetMat.freeDev(devWSVal, devWSRowPtr, devWSColInd, devWSSelfDot);
    TIMER_STOP(preComputeTimer)
}

real MultiSmoSolver::getObjValue(int numOfSamples) const {
    //the function should be called before deinit4Training
    vector<real> f(numOfSamples);
    vector<real> alpha(numOfSamples);
    vector<int> y(numOfSamples);
    cudaMemcpy(f.data(), devYiGValue, sizeof(real) * numOfSamples, cudaMemcpyDeviceToHost);
    cudaMemcpy(alpha.data(), devAlpha, sizeof(real) * numOfSamples, cudaMemcpyDeviceToHost);
    cudaMemcpy(y.data(), devLabel, sizeof(int) * numOfSamples, cudaMemcpyDeviceToHost);
    real obj = 0;
    for (int i = 0; i < numOfSamples; ++i) {
        obj -= alpha[i];
    }
    for (int i = 0; i < numOfSamples; ++i) {
            obj += 0.5 * alpha[i] * y[i] * (f[i] + y[i]);
    }
    return obj;
}


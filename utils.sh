#!/bin/bash -eu

function wait_till_instance_not_exist() {
    local INSTANCE_NAME=$1
    local ZONE=$2
    if [ "$#" -ne 2 ]; then
        echo "Usage: "
        echo "   ./wait_till_instance_not_exist [INSTANCE_NAME] [ZONE]"
        echo ""
        echo "example:"
        echo "   ./wait_till_instance_not_exist instance1 us-west1-b"
        echo ""
        return 1
    fi
    gcloud compute instances tail-serial-port-output "${INSTANCE_NAME}" --zone="${ZONE}" || true
    return 0
}

function execute_notebook() {
    local ZONE="us-west1-b"
    local IMAGE_FAMILY="tf-latest-gpu"
    local INPUT_NOTEBOOK=""
    local GPU_TYPE=""
    local GPU_COUNT=1
    local INSTANCE_TYPE="n1-standard-8"
    local GCS_LOCATION=""
    local BUILD_ID=$(date +%s)

    while getopts "i:z:f:g:c:t:l:o:h" opt; do
    case ${opt} in
        i )
        INPUT_NOTEBOOK=$OPTARG
        ;;
        z )
        ZONE=$OPTARG
        ;;
        f )
        IMAGE_FAMILY=$OPTARG
        ;;
        g )
        GPU_TYPE=$OPTARG
        ;;
        c )
        GPU_COUNT=$OPTARG
        ;;
        t )
        INSTANCE_TYPE=$OPTARG
        ;;
        o )
        GCS_LOCATION=$OPTARG
        ;;
        h )
        echo "Usage: "
        echo "   ./execute_notebook_with_gpu -i [INPUT_NOTEBOOK] -o [GCS_OUTPUT_LOCATION] -g [GPU_TYPE] -c [GPU_COUNT] -z [ZONE] -t [INSTANCE_TYPE] -f [IMAGE_FAMILY]"
        echo ""
        echo "example:"
        echo "   ./execute_notebook_with_gpu -i test.ipynb -o gs://my-bucket -g p100 -c 4 -z us-west1-b -t n1-standard-8 -f tf-latest-gpu"
        echo ""
        echo "default values:"
        echo "   gpu type: empty (no GPU will be used for training)"
        echo "   gpu count: 1"
        echo "   image family: tf-latest-gpu"
        echo "   zone: us-west1-b"
        echo "   instance-type: n1-standard-8"
        echo ""
        return 1
        ;;
        \? )
        echo "Invalid option: $OPTARG" 1>&2
        return 1
        ;;
        : )
        echo "Invalid option: $OPTARG requires an argument" 1>&2
        return 1
        ;;
    esac
    done
    shift $((OPTIND -1))

    echo "Build id: ${BUILD_ID}"

    if [[ -z "${INPUT_NOTEBOOK}" ]]; then
        echo "input notebook field is empty (use key -i)"
        return 1
    fi
    local NOTEBOOK_NAME=$(basename "${INPUT_NOTEBOOK}")

    if [[ -z "${GCS_LOCATION}" ]]; then
        echo "GCS output location field is empty (use key -o)"
        return 1
    fi
    local INPUT_NOTEBOOK_GCS_PATH="${GCS_LOCATION}/staging/${BUILD_ID}/${NOTEBOOK_NAME}"

    if [[ ! -z ${PARAM_FILE} ]]; then
        INPUT_PARAM_GCS_PATH="${GCS_LOCATION}/staging/${BUILD_ID}/params.yaml"
        gsutil cp "${PARAM_FILE}" "${INPUT_PARAM_GCS_PATH}"
        PARAM_METADATA=",parameters_file=${INPUT_PARAM_GCS_PATH}"
    fi
    echo "Staging notebook: ${INPUT_NOTEBOOK_GCS_PATH}"
    echo "Output notebook: ${GCS_LOCATION}"
    gsutil cp "${INPUT_NOTEBOOK}" "${INPUT_NOTEBOOK_GCS_PATH}"
    if [[ $? -eq 1 ]]; then
        echo "Upload to the temp GCS location (${INPUT_NOTEBOOK_GCS_PATH}) of the notebook (${INPUT_NOTEBOOK}) has failed."
        return 1
    fi
    INSTANCE_NAME="notebookexecutor-${BUILD_ID}"
    if [[ -z "${GPU_TYPR}" ]]; then
        gcloud compute instances create "${INSTANCE_NAME}" \
                --zone="${ZONE}" \
                --image-family="${IMAGE_FAMILY}" \
                --image-project=deeplearning-platform-release \
                --maintenance-policy=TERMINATE \
                --machine-type="${INSTANCE_TYPE}" \
                --boot-disk-size=200GB \
                --scopes=https://www.googleapis.com/auth/cloud-platform \
                --metadata="api_key=${API_KEY},input_notebook=${INPUT_NOTEBOOK_GCS_PATH},output_notebook=${GCS_LOCATION}${PARAM_METADATA:-},startup-script-url=https://raw.githubusercontent.com/gclouduniverse/gcp-notebook-executor/submission_extraction/notebook_executor.sh" \
                --quiet
    else
        gcloud compute instances create "${INSTANCE_NAME}" \
                --zone="${ZONE}" \
                --image-family="${IMAGE_FAMILY}" \
                --image-project=deeplearning-platform-release \
                --maintenance-policy=TERMINATE \
                --accelerator="type=nvidia-tesla-${GPU_TYPE},count=${GPU_COUNT}" \
                --machine-type="${INSTANCE_TYPE}" \
                --boot-disk-size=200GB \
                --scopes=https://www.googleapis.com/auth/cloud-platform \
                --metadata="api_key=${API_KEY},input_notebook=${INPUT_NOTEBOOK_GCS_PATH},output_notebook=${GCS_LOCATION}${PARAM_METADATA:-},startup-script-url=https://raw.githubusercontent.com/gclouduniverse/gcp-notebook-executor/submission_extraction/notebook_executor.sh" \
                --quiet
    fi
    if [[ $? -eq 1 ]]; then
        echo "Creation of background instance for training has failed."
        return 1
    fi
    wait_till_instance_not_exist "${INSTANCE_NAME}" "${ZONE}"
    echo "execution has been finished, checking result"
    OUTPUT_CONTENTS=$(gsutil ls "${GCS_LOCATION}")
    if [[ $? -ne 0 ]] || grep -q "FAILED" <<< "${OUTPUT_CONTENTS}"; then
        echo "Job failed or unable to get output."
        return 1
    fi
    echo "done"
    return 0
}

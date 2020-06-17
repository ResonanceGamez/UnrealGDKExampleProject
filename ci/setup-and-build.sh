#!/usr/bin/env bash

set -e -u -o pipefail
if [[ -n "${DEBUG-}" ]]; then
    set -x
fi

source /opt/improbable/environment

run_uat() {
    ENGINE_DIRECTORY="${1}"
    EXAMPLEPROJECT_HOME="${2}"
    CLIENT_CONFIG="${3}"
    TARGET_PLATFORM="${4}"
    ARCHIVE_DIRECTORY="${5}"
    ADDITIONAL_UAT_FLAGS="${6:-}"
    ADDITIONAL_COMMAND_LINE="${7:-}"

    ${ENGINE_DIRECTORY}/Engine/Build/BatchFiles/RunUAT.sh \
        -ScriptsForProject="${EXAMPLEPROJECT_HOME}/Game/GDKShooter.uproject" \
        BuildCookRun \
        -nocompileeditor \
        -nop4 \
        -project="${EXAMPLEPROJECT_HOME}/Game/GDKShooter.uproject" \
        -cook \
        -stage \
        -archive \
        -archivedirectory="${ARCHIVE_DIRECTORY}" \
        -package \
        -clientconfig="${CLIENT_CONFIG}" \
        -ue4exe="${EXAMPLEPROJECT_HOME}/UnrealEngine/Engine/Binaries/Mac/UE4Editor-Cmd" \
        -pak \
        -prereqs \
        -nodebuginfo \
        -targetplatform="${TARGET_PLATFORM}" \
        -build \
        -utf8output \
        -compile \
        -cmdline="${ADDITIONAL_COMMAND_LINE}" \
        "${ADDITIONAL_UAT_FLAGS}"
}

check_result(){
    TEST_LAB_PATH="${1}"
    DEVICE="${2}"

    SYSLOG_TXT="syslog.txt"
    rm -f ${SYSLOG_TXT}
    echo "--- download syslog.log from firebase${TEST_LAB_PATH}"
    gsutil cp gs://${TEST_LAB_PATH}${DEVICE}/${SYSLOG_TXT} ${SYSLOG_TXT}

    if [ -x "$SYSLOG_TXT" ]; then
        echo "--- analyze firebase log"
        grep "prod" ${SYSLOG_TXT} > /dev/null
        if [ `grep -c "PlayerSpawn returned from server sucessfully" ${SYSLOG_TXT}` -eq '0' ]; then
            return 0
        else
            return 1
        fi
    else
        return 0
    fi
}

GDK_REPO="${1:-git@github.com:spatialos/UnrealGDK.git}"
GCS_PUBLISH_BUCKET="${2:-io-internal-infra-unreal-artifacts-production/UnrealEngine}"

pushd "$(dirname "$0")"
    EXAMPLEPROJECT_HOME="$(pwd)/.."
    GDK_BRANCH_NAME="${GDK_BRANCH:-master}"
    GDK_HOME="${EXAMPLEPROJECT_HOME}/Game/Plugins/UnrealGDK"

    echo "--- show gcloud components list"
    gcloud components list

    echo "--- install beta component of gcloud"
    gcloud components install beta

    echo "--- clone-gdk-plugin"
    mkdir -p "${EXAMPLEPROJECT_HOME}/Game/Plugins"
    pushd "${EXAMPLEPROJECT_HOME}/Game/Plugins/"
        git clone ${GDK_REPO} \
            --branch ${GDK_BRANCH_NAME}  \
            --single-branch \
            --depth 1
    popd

    echo "--- print-head-gdk-commit"
    pushd "${GDK_HOME}"
        GDK_COMMIT_HASH=$(git rev-parse HEAD | cut -c1-6)
        echo "GDK at commit: ${GDK_COMMIT_HASH} on branch ${GDK_BRANCH_NAME}"
    popd

    echo "--- set-up-gdk-plugin"
    "${GDK_HOME}/Setup.sh" --mobile

    echo "--- set-up-engine"
    ENGINE_DIRECTORY="${EXAMPLEPROJECT_HOME}/UnrealEngine"
    "${GDK_HOME}/ci/get-engine.sh" \
        "${ENGINE_DIRECTORY}" \
        "${GCS_PUBLISH_BUCKET}"


    pushd "${ENGINE_DIRECTORY}"
        echo "--- create-xcode-project"
        Engine/Build/BatchFiles/Mac/Build.sh \
            -projectfiles \
            -project="${EXAMPLEPROJECT_HOME}/Game/GDKShooter.uproject" \
            -game \
            -engine \
            -progress

        echo "--- build-unreal-editor"
        Engine/Build/BatchFiles/Mac/XcodeBuild.sh \
            GDKShooterEditor \
            Mac \
            Development \
            "${EXAMPLEPROJECT_HOME}/Game/GDKShooter.uproject"

        echo "--- generate-schema"
        pushd "Engine/Binaries/Mac"
            UE4Editor.app/Contents/MacOS/UE4Editor \
                "${EXAMPLEPROJECT_HOME}/Game/GDKShooter.uproject" \
                -run=CookAndGenerateSchema \
                -targetplatform=MacNoEditor \
                -SkipShaderCompile \
                -unversioned \
                -map="/Maps/FPS-Start_Small"

            UE4Editor.app/Contents/MacOS/UE4Editor \
                "${EXAMPLEPROJECT_HOME}/Game/GDKShooter.uproject" \
                -run=GenerateSchemaAndSnapshots \
                -MapPaths="/Maps/FPS-Start_Small" \
                -SkipSchema
        popd
    popd

    echo "--- build-mac-client"
    run_uat \
        "${ENGINE_DIRECTORY}" \
        "${EXAMPLEPROJECT_HOME}" \
        "Development" \
        "Mac" \
        "${EXAMPLEPROJECT_HOME}/cooked-mac" \
        "-iterative"

    # echo "--- build-ios-client"
    # run_uat \
    #     "${ENGINE_DIRECTORY}" \
    #     "${EXAMPLEPROJECT_HOME}" \
    #     "Development" \
    #     "IOS" \
    #     "${EXAMPLEPROJECT_HOME}/cooked-ios" \
    #     ""

    COOK_FOLDER="cooked-firebase-ios"

    #modify iosRuntimeSettings to add additional ios settings to DefaultEngine.ini
    DEFAULTEINGINE_CONFIGURATION="DefaultEngine.ini"
    echo "--- backup ${DEFAULTEINGINE_CONFIGURATION}"
    DEFAULTENGINE="${EXAMPLEPROJECT_HOME}/Game/Config/${DEFAULTEINGINE_CONFIGURATION}"
    BACKUP_DEFAULTENGINE="Original${DEFAULTEINGINE_CONFIGURATION}"
    cp ${DEFAULTENGINE} ${BACKUP_DEFAULTENGINE}
    sed '/IOSRuntimeSettings]/r iosRuntimeSettings.txt' ${BACKUP_DEFAULTENGINE} > ${DEFAULTENGINE}

    #modify spatialos.json to add cloud deployment settings
    SPATIALOS_CONFIGURATION="spatialos.json"
    echo "--- backup ${SPATIALOS_CONFIGURATION}"
    SPATIALOS_JSON=${EXAMPLEPROJECT_HOME}/spatial/${SPATIALOS_CONFIGURATION}
    echo "SPATIALOS_JSON:"${SPATIALOS_JSON}
    BACKUP_SPATIALOS_JSON="Original${SPATIALOS_CONFIGURATION}"
    cp ${SPATIALOS_JSON} ${BACKUP_SPATIALOS_JSON}
    sed 's/your_project_name_here/beta_failed_tennessee_213/g' ${BACKUP_SPATIALOS_JSON} > ${SPATIALOS_JSON}

    echo "--- build-firebase-ios-client"
    run_uat \
        "${ENGINE_DIRECTORY}" \
        "${EXAMPLEPROJECT_HOME}" \
        "Development" \
        "IOS" \
        "${EXAMPLEPROJECT_HOME}/${COOK_FOLDER}" \
        "" \
        "connect.to.spatialos -workerType UnrealClient -devauthToken MDcxNTJmZGYtYmI4ZC00YjJlLTliY2MtY2EzYTBlYTQ4NWEyOjpjNWEwNGZkZi1hNWU1LTRhN2UtOWY5OC1iMWIxZGViZTViNmM= -deployment kenyu_test"

    echo "--- recover ${DEFAULTEINGINE_CONFIGURATION}"
    cp ${BACKUP_DEFAULTENGINE} ${DEFAULTENGINE}

    echo "--- recover ${SPATIALOS_CONFIGURATION}"
    cp ${BACKUP_SPATIALOS_JSON} ${SPATIALOS_JSON}

    TEST_LAB_PATH=""
    echo "--- upload and analyze firebase log"
    KEYWORD="https://console.developers.google.com/storage/browser/"
    for info in $(gcloud beta firebase test ios run --type game-loop --app ${EXAMPLEPROJECT_HOME}/${COOK_FOLDER}/IOS/GDKShooter.ipa --scenario-numbers 1 2>&1)
    do
        echo ${info}
        if [ -n "$info" ] 
        then
            if [[ $info =~ "${KEYWORD}" ]] 
            then
                URL=`expr $info : '.*\[\(.*\)\]'`
                TEST_LAB_PATH=${URL:${#KEYWORD}}
                echo ${TEST_LAB_PATH}
            fi
        fi
    done

    echo "TEST_LAB_PATH:${TEST_LAB_PATH}"
    if check_result ${TEST_LAB_PATH} "iphone8-11.2-en-portrait"
    then
        echo "Test SpatialOS Connection Failed"
    else
        echo "Test SpatialOS Connection Succeed"
    fi
popd

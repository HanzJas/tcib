#!/bin/sh

set -x

HORIZONTEST_DIR=/var/lib/horizontest
HORIZON_LOGS_DIR_NAME=${HORIZON_LOGS_DIR_NAME:-"horizon"}
IMAGE_FILE="/var/lib/horizontest/cirros-0.6.2-x86_64-disk.img"
IMAGE_FILE_NAME=cirros-0.6.2-x86_64-disk
IMAGE_FILE_NAME_WITH_SIZE="cirros-0.6.2-x86_64-disk (20.4 MB)"
IMAGE_URL=http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
PROJECT_NAME=horizontest
USER_NAME=horizontest
PASSWORD=horizontest
FLAVOR_NAME=m1.tiny
GROUP_NAME=admins
SELENIUM_EXPLICIT_WAIT=180
SELENIUM_PAGE_TIMEOUT=120
SELENIUM_IMPLICIT_WAIT=30
HORIZONTEST_DEBUG_MODE="${HORIZONTEST_DEBUG_MODE:-false}"

# This is an empty test PR

# assert mandatory variables have been set
[[ -z ${ADMIN_USERNAME} ]] && echo "ADMIN_USERNAME not set" && exit 1
[[ -z ${ADMIN_PASSWORD} ]] && echo "ADMIN_PASSWORD not set" && exit 1
[[ -z ${DASHBOARD_URL} ]] && echo "DASHBOARD_URL not set" && exit 1
[[ -z ${AUTH_URL} ]] && echo "AUTH_URL not set" && exit 1
[[ -z ${REPO_URL} ]] && REPO_URL="https://review.opendev.org/openstack/horizon"
[[ -z ${HORIZON_REPO_BRANCH} ]] && HORIZON_REPO_BRANCH="master"

function catch_error_if_debug {
    echo "File run_horizontest.sh has run into an error!"
    sleep infinity
}

# Catch errors when in debug mode
if [ ${HORIZONTEST_DEBUG_MODE} == true ]; then
    trap catch_error_if_debug ERR
fi

#This function is temporarily added until tempest cleanup is implemented
function clean_leftover_images {
    openstack image list -c Name -f value --os-cloud default | xargs -I {} openstack image delete {} --os-cloud default
}

function create_custom_resources {
    if ! openstack image show --os-cloud default ${IMAGE_FILE_NAME} ; then
        if [ ! -f "$IMAGE_FILE" ]; then
            curl -o "$IMAGE_FILE" -OL ${IMAGE_URL}
        fi
        openstack image create \
                --os-cloud default \
                --disk-format qcow2 \
                --container-format bare \
                --file "$IMAGE_FILE" --public ${IMAGE_FILE_NAME}
    fi

    if ! openstack project show --os-cloud default ${PROJECT_NAME} ; then
        openstack project create \
                --os-cloud default \
                --description 'Horizon Selenium test project' ${PROJECT_NAME}
    fi

    if ! openstack user show --os-cloud default ${USER_NAME}; then
        openstack user create \
                --os-cloud default \
                --project ${PROJECT_NAME} \
                --password ${PASSWORD} ${USER_NAME}
    fi

    openstack role add \
            --os-cloud default \
            --user ${USER_NAME} \
            --project ${PROJECT_NAME} member

    if ! openstack flavor show --os-cloud default ${FLAVOR_NAME}; then
        openstack flavor create \
                --os-cloud default \
                --public ${FLAVOR_NAME} \
                --ram 512 --disk 1 --vcpus 1
    fi

    if ! openstack group show --os-cloud default ${GROUP_NAME}; then
        openstack group create \
                --os-cloud default ${GROUP_NAME}
    fi
}

function delete_custom_resources {
    if openstack image show --os-cloud default ${IMAGE_FILE_NAME}; then
        openstack image delete \
                --os-cloud default ${IMAGE_FILE_NAME}
    fi

    if openstack project show --os-cloud default ${PROJECT_NAME}; then
        openstack project delete \
                --os-cloud default ${PROJECT_NAME}
    fi

    if openstack user show --os-cloud default ${USER_NAME}; then
        openstack user delete \
                --os-cloud default ${USER_NAME}
    fi

    if openstack flavor show --os-cloud default ${FLAVOR_NAME}; then
        openstack flavor delete \
                --os-cloud default ${FLAVOR_NAME}
    fi

    if openstack group show --os-cloud default ${GROUP_NAME}; then
        openstack group delete \
                --os-cloud default ${GROUP_NAME}
    fi
}

pushd ${HORIZONTEST_DIR}
git clone ${REPO_URL} ${HORIZONTEST_DIR}/horizon
chown -R horizontest:horizontest horizon
pushd horizon
git pull --rebase
git checkout ${HORIZON_REPO_BRANCH}

clean_leftover_images
create_custom_resources
pushd ${HORIZONTEST_DIR}/horizon/openstack_dashboard/test/integration_tests/

# set variables in horizon.conf
crudini --set horizon.conf dashboard dashboard_url ${DASHBOARD_URL}/dashboard/
crudini --set horizon.conf dashboard auth_url ${AUTH_URL}
crudini --set horizon.conf identity username ${USER_NAME}
crudini --set horizon.conf identity password ${PASSWORD}
crudini --set horizon.conf identity home_project ${PROJECT_NAME}
crudini --set horizon.conf identity admin_username ${ADMIN_USERNAME}
crudini --set horizon.conf identity admin_password ${ADMIN_PASSWORD}
crudini --set horizon.conf image http_image ${IMAGE_URL}
crudini --set horizon.conf image images_list ${IMAGE_FILE_NAME}
crudini --set horizon.conf launch_instances image_name "${IMAGE_FILE_NAME_WITH_SIZE}"
crudini --set horizon.conf selenium explicit_wait ${SELENIUM_EXPLICIT_WAIT}
crudini --set horizon.conf selenium page_timeout ${SELENIUM_PAGE_TIMEOUT}
crudini --set horizon.conf selenium implicit_wait ${SELENIUM_IMPLICIT_WAIT}
popd

# run horizon selenium tests
INTEGRATION_TESTS=1 SELENIUM_HEADLESS=1 pytest openstack_dashboard/test/selenium/integration/ -k "not pagination" \
        --junitxml="test_reports/ui_integration_test_results.xml" \
        --html="test_reports/ui_integration_test_results.html" --self-contained-html
RETURN_VALUE=$?

# copy logs to external_files
echo "Copying logs file"
LOG_DIR=${HORIZONTEST_DIR}/external_files/${HORIZON_LOGS_DIR_NAME}/
mkdir -p ${LOG_DIR}
cp -rf ${HORIZONTEST_DIR}/horizon/test_reports/* ${LOG_DIR}

delete_custom_resources

# Keep pod in running state when in debug mode
if [ ${HORIZONTEST_DEBUG_MODE} == true ]; then
    sleep infinity
fi

exit ${RETURN_VALUE}

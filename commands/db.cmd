#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

WARDEN_ENV_PATH="$(locateEnvPath)" || exit $?
loadEnvConfig "${WARDEN_ENV_PATH}" || exit $?
assertDockerRunning

if [[ ${WARDEN_DB:-1} -eq 0 ]]; then
  fatal "Database environment is not used (WARDEN_DB=0)."
fi

if (( ${#WARDEN_PARAMS[@]} == 0 )) || [[ "${WARDEN_PARAMS[0]}" == "help" ]]; then
  $WARDEN_BIN db --help || exit $? && exit $?
fi

## load connection information for the mysql service
DB_CONTAINER=$($WARDEN_BIN env ps -q db)
if [[ ! ${DB_CONTAINER} ]]; then
    fatal "No container found for db service."
fi

eval "$(
    docker container inspect ${DB_CONTAINER} --format '
        {{- range .Config.Env }}{{with split . "=" -}}
            {{- index . 0 }}='\''{{ range $i, $v := . }}{{ if $i }}{{ $v }}{{ end }}{{ end }}'\''{{println}}
        {{- end }}{{ end -}}
    ' | grep "^MYSQL_"
)"

## sub-command execution
case "${WARDEN_PARAMS[0]}" in
    connect)
        "$WARDEN_BIN" env exec db \
            mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --database="${MYSQL_DATABASE}" "${WARDEN_PARAMS[@]:1}" "$@"
        ;;
    import)
        LC_ALL=C sed -E 's/DEFINER[ ]*=[ ]*`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' \
            | LC_ALL=C sed -E '/\@\@(GLOBAL\.GTID_PURGED|SESSION\.SQL_LOG_BIN)/d' \
            | "$WARDEN_BIN" env exec -T db \
            mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --database="${MYSQL_DATABASE}" "${WARDEN_PARAMS[@]:1}" "$@"
        ;;
    dump)
        if [[ "${WARDEN_PARAMS[1]}" == "--cloud" ]]; then
            # Check if magento-cloud is installed
            if ! command -v magento-cloud &> /dev/null; then
                fatal "magento-cloud CLI is not installed. Please install it first: https://experienceleague.adobe.com/en/docs/commerce-cloud-service/user-guide/dev-tools/cloud-cli/cloud-cli-overview"
            fi

            # Check if the user is logged into magento-cloud
            if ! magento-cloud auth:info &> /dev/null; then
                fatal "You are not logged into magento-cloud. Please run 'magento-cloud login' first."
            fi

            # Extract the environment from the parameters
            environment="${WARDEN_PARAMS[3]}"
            if [[ -z "$environment" ]]; then
                fatal "Environment not specified. Usage: warden db-dump --cloud --environment <environment>"
            fi

            # Run the magento-cloud command with a timeout
            timeout 30s magento-cloud db:dump -p "$WARDEN_ENV_NAME" -e "$environment" || fatal "Command timed out. Make sure you're connected to the correct project and environment."
        else
            "$WARDEN_BIN" env exec -T db \
                mysqldump -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" "${WARDEN_PARAMS[@]:1}" "$@"
        fi
        ;;
    *)
        fatal "The command \"${WARDEN_PARAMS[0]}\" does not exist. Please use --help for usage."
        ;;
esac

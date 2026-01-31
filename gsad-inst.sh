#!/bin/bash
USER="$1"
GVMD_HOST="$2"
GVMD_PORT="$3"
# -----------------------------------
# Раздел: Логирование
# -----------------------------------

# Путь к файлу лога
LOG_FILE=/var/log/openvas_install.log

# Структурирует логирование с уровнями (INFO, WARN, ERROR)
# Вид логов: log <УРОВЕНЬ> <СООБЩЕНИЕ>
log() {
	local level=$1              
	shift                       
	local message="$*"          
	
	local timestamp=$(date '+%Y-%m-%d %H:%M:%S')  
	
	# ANSI-коды цветов для терминала
	local COLOR_INFO="\033[1;36m"   
	local COLOR_WARN="\033[1;33m"   
	local COLOR_ERROR="\033[1;31m"  
	local COLOR_RESET="\033[0m"     
	
	# Выбор цвета в зависимости от уровня лога
	case "$level" in
		INFO)
			color=$COLOR_INFO     
			;;
		WARN)
			color=$COLOR_WARN     
			;;
		ERROR)
			color=$COLOR_ERROR    
			;;
		*)
			color=$COLOR_RESET    
			;;
	esac
	
	# Вывод сообщения
	echo -e "${color}${timestamp} [$level] $message${COLOR_RESET}" | tee -a "$LOG_FILE"
}

# Логирует выполнение команды и завершает скрипт при ошибке с кодом выхода
run_command() {
	log INFO "Executing command: $*"
	"$@"
	local status=$?
	if [ $status -ne 0 ]; then
		log ERROR "Command '$*' failed with status $status."
		exit $status
	fi
	log INFO "Command '$*' completed successfully."
}

# -----------------------------------
# Раздел: Настройка окружения
# -----------------------------------

# Настраивает переменные окружения для процесса установки
# Создаёт единые пути для директорий исходников, сборки и установки
set_environment() {
    export HOME=/root
	log INFO "Starting environment variable setup..."
	export INSTALL_PREFIX=/usr/local
	export PATH=$PATH:$INSTALL_PREFIX/sbin                                              
	export SOURCE_DIR=$HOME/source                          
	export BUILD_DIR=$HOME/build                              
	export INSTALL_DIR=$HOME/install
	export GNUPGHOME=/tmp/openvas-gnupg
	export OPENVAS_GNUPG_HOME=/etc/openvas/gnupg                                  

	for dir in "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"; do
		if ! mkdir -p "$dir" 2>/dev/null; then                 
			log ERROR "Failed to create directory $dir. Check permissions or disk space."
			exit 1                                               
		fi
		local free_space                                          
		free_space=$(df -k "$dir" | tail -1 | awk '{print $4}')  
		if [ "$free_space" -lt 1048576 ]; then                   
			log WARN "Low disk space in $dir: $((free_space/1024)) MB available. Recommend at least 1GB."
		fi
	done
	
	log INFO "Environment variable set: INSTALL_PREFIX=$INSTALL_PREFIX"
	log INFO "Environment variable set: PATH=$PATH"
	log INFO "Environment variable set: SOURCE_DIR=$SOURCE_DIR"
	log INFO "Environment variable set: BUILD_DIR=$BUILD_DIR"
	log INFO "Environment variable set: INSTALL_DIR=$INSTALL_DIR"
	log INFO "Environment variable set: GNUPGHOME=$GNUPGHOME"
	log INFO "Environment variable set: OPENVAS_GNUPG_HOME=$OPENVAS_GNUPG_HOME"
}

# -----------------------------------
# Раздел: Управление пользователями и группами
# -----------------------------------

# Создает пользователя и группу 'gvm' для запуска сервисов OpenVAS.
create_gvm_user() {
	log INFO "Setting up GVM user and group..."
	if getent passwd gvm > /dev/null 2>&1; then
		log WARN "GVM user already exists, skipping creation. Verify user settings."
	else
		run_command useradd -r -m -U -G sudo -s /usr/sbin/nologin gvm
		if ! run_command usermod -aG gvm "$USER"; then
			log WARN "Failed to add $USER to gvm group. Manual addition may be required."
		else
			log INFO "Created GVM user and group, added $USER to gvm group."
		fi
	fi
}


# -----------------------------------
# Раздел: Управление версиями
# -----------------------------------

# Получает последние версии компонентов OpenVAS с GitHub.
# Экспортирует номера версий как переменные окружения для использования в установке.
check_latest_version() {
	log INFO "Starting version check for OpenVAS components..."

	# Проверяем сетевую доступность к API GitHub
	if ! curl --proto '=https' --tlsv1.2 -s -I "https://api.github.com" >/dev/null 2>&1; then
		log ERROR "No network connectivity to api.github.com. Check network settings."
		exit 1
	fi

	declare -A component_vars=(
		["gvm-libs"]="GVM_LIBS_VERSION"
		["gsa"]="GSA_VERSION"
		["gsad"]="GSAD_VERSION"
	)

	for component in "${!component_vars[@]}"; do
		log INFO "Fetching latest version for $component..."
		local comp_ver
		comp_ver=$(curl --proto '=https' --tlsv1.2 -s "https://api.github.com/repos/greenbone/$component/releases/latest" | grep tag_name | cut -d '"' -f 4 | sed 's/v//')

		if [ -z "$comp_ver" ]; then
			log ERROR "Failed to fetch version for $component. Check network or GitHub API."
			exit 1
		fi

		local var_name="${component_vars[$component]}"
		export "$var_name=$comp_ver"
		log INFO "Set $var_name=$comp_ver"
		
	done
	log INFO "Completed version check for all components."
}

# -----------------------------------
# Раздел: Установка зависимостей
# -----------------------------------

# Устанавливает общие инструменты сборки и зависимости, необходимые для всех компонентов.
install_common_dep() {
	log INFO "Installing common build dependencies..."
	
	# Очистка кэша
	run_command apt clean
	run_command apt update
	
	if ! run_command apt install --no-install-recommends --assume-yes \
		build-essential curl cmake pkg-config python3 python3-pip gnupg; then
		log ERROR "Failed to install common dependencies. Check apt configuration."
		exit 1
	fi
	if ! command -v cmake >/dev/null 2>&1; then
		log ERROR "cmake not found after installation. Dependency installation incomplete."
		exit 1
	fi
	log INFO "Common dependencies installed."
}

install_gvm_libs_dep() {
    log INFO "Installing gvm-libs dependencies..."
    
    # Очистка кэша
    run_command apt clean
    run_command apt update
    
    # Обязательные зависимости для компонента gvm-libs
    if ! run_command apt install -y libcjson-dev libcurl4-gnutls-dev libgcrypt-dev libglib2.0-dev libgnutls28-dev libgpgme-dev libhiredis-dev libnet1-dev libpaho-mqtt-dev libpcap-dev libssh-dev libxml2-dev uuid-dev; then
        log ERROR "Failed to install required dependencies for gvm-libs. Check apt configuration."
        exit 1
    fi
    
    # Дополнительные зависимости для компонента gvm-libs
    if ! run_command apt install -y libldap2-dev libradcli-dev; then
        log WARN "Optional gvm-libs dependencies (libldap2-dev, libradcli-dev) not installed. Some features may be limited."
    fi
    
    log INFO "gvm-libs dependencies installed."
}


# Устанавливает зависимости для компонента gsad
install_gsad_dep() {
	log INFO "Installing gsad dependencies..."
	# Требуемые зависимости для gsad
	if ! run_command apt install -y \
		libbrotli-dev libglib2.0-dev libgnutls28-dev libmicrohttpd-dev libxml2-dev; then
		log ERROR "Failed to install required dependencies for gsad. Check apt configuration."
		exit 1
	fi
	log INFO "gsad dependencies installed."
}


# Устанавливает все необходимые зависимости для компонентов OpenVAS.
install_packages() {
	log INFO "Starting installation of all dependencies..."
	for dep_func in install_common_dep install_gvm_libs_dep install_gsad_dep; do
		if ! $dep_func; then
			log ERROR "Failed to install dependencies in $dep_func."
			exit 1
		fi
	done
	log INFO "All dependencies installed successfully."
}


# -----------------------------------
# Раздел: Настройка директорий и ключей
# -----------------------------------

# Создает директории для исходников, сборки и установки.
create_directories() {
	log INFO "Creating directories for source, build, and installation..."
	for dir in "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"; do
		if ! mkdir -p "$dir" 2>/dev/null; then
			log ERROR "Failed to create directory $dir. Check permissions or disk space."
			exit 1
		fi
		if [ ! -w "$dir" ]; then
			log ERROR "Directory $dir is not writable. Check permissions."
			exit 1
		fi
	done
	log INFO "Directories created: $SOURCE_DIR, $BUILD_DIR, $INSTALL_DIR"
}

# мпортирует GPG ключ подписи Greenbone для проверки пакетов.
import_signing_key() {
	log INFO "Importing Greenbone Community Signing Key..."
	
	if ! run_command mkdir -p "$GNUPGHOME"; then
		log ERROR "Failed to create GPG home directory $GNUPGHOME."
		exit 1
	fi
	
	if ! run_command curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc; then
		log ERROR "Failed to download Greenbone signing key. Check network or URL."
		exit 1
	fi
	
	if ! run_command gpg --homedir "$GNUPGHOME" --import /tmp/GBCommunitySigningKey.asc; then
		log ERROR "Failed to import Greenbone signing key. Check GPG configuration."
		exit 1
	fi
	
	# Проверяет наличие ключа Greenbone в хранилище
	if ! gpg --homedir "$GNUPGHOME" --list-keys | grep -q "Greenbone"; then
		log WARN "Greenbone key imported but not found in keyring. Verification may fail."
	fi
	
	log INFO "Greenbone signing key imported."
}

# -----------------------------------
# Раздел: Установка компонентов
# -----------------------------------

# Собирает и устанавливает универсальный компонент OpenVAS из исходников.
build_install_component() {
	local comp_name=$1
	local comp_ver=$2
	local comp_args=$3

	log INFO "Starting build and installation of $comp_name-$comp_ver..."

	# Устанавливаем URL исходников
	local comp_src="https://github.com/greenbone/$comp_name/archive/refs/tags/v$comp_ver.tar.gz"

	# Устанавливаем URL подписи GPG
	local comp_sig="https://github.com/greenbone/$comp_name/releases/download/v$comp_ver/$comp_name-$comp_ver.tar.gz.asc"

	# Скачиваем исходники
	if ! run_command curl -f -L "$comp_src" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
		log ERROR "Failed to download source for $comp_name-$comp_ver from $comp_src"
		exit 1
	fi
	if ! run_command curl -f -L "$comp_sig" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc"; then
		log ERROR "Failed to download signature for $comp_name-$comp_ver from $comp_sig"
		exit 1
	fi		

	# Проверяем GPG подпись
	if ! gpg --homedir "$GNUPGHOME" --verify "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc" "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
		log ERROR "GPG signature verification failed for $comp_name-$comp_ver"
		exit 1
	fi

	# Распаковываем исходники
	if ! run_command tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
		log ERROR "Failed to extract source for $comp_name-$comp_ver"
		exit 1
	fi

	# Сборка
	if ! run_command mkdir -p "$BUILD_DIR/$comp_name"; then
		log ERROR "Failed to create build directory $BUILD_DIR/$comp_name"
		exit 1
	fi
	if ! run_command cmake $comp_args; then
		log ERROR "CMake configuration failed for $comp_name-$comp_ver with args: $comp_args"
		exit 1
	fi
	if ! run_command cmake --build "$BUILD_DIR/$comp_name" -j$(nproc); then
		log ERROR "Build failed for $comp_name-$comp_ver"
		exit 1
	fi

	# Установка
	if ! run_command mkdir -p "$INSTALL_DIR/$comp_name"; then
		log ERROR "Failed to create install directory $INSTALL_DIR/$comp_name"
		exit 1
	fi
	if ! run_command cd "$BUILD_DIR/$comp_name"; then
		log ERROR "Failed to change to build directory $BUILD_DIR/$comp_name"
		exit 1
	fi
	if ! run_command make DESTDIR="$INSTALL_DIR/$comp_name" install; then
		log ERROR "Installation failed for $comp_name-$comp_ver"
		exit 1
	fi
	if ! run_command cp -rv "$INSTALL_DIR/$comp_name"/* /; then
		log ERROR "Failed to copy installed files for $comp_name-$comp_ver to system directories"
		exit 1
	fi
	
	# Обновляем кэш динамических библиотек
    	if ! run_command ldconfig; then
        	log WARN "ldconfig failed but continuing installation."
		exit 1
    	else
        	log INFO "Library cache updated with ldconfig for $comp_name."
    	fi

	log INFO "Successfully built and installed $comp_name-$comp_ver"
}

# Устанавливает веб-интерфейс GSA (Greenbone Security Assistant).
build_install_gsa() {
	local comp_name=$1
	local comp_ver=$2

	log INFO "Starting installation of $comp_name-$comp_ver..."

	local comp_src="https://github.com/greenbone/gsa/releases/download/v$comp_ver/gsa-dist-$comp_ver.tar.gz"
	local comp_sig="https://github.com/greenbone/gsa/releases/download/v$comp_ver/gsa-dist-$comp_ver.tar.gz.asc"

	# Скачивание и проверка подписи
	log INFO "Downloading $comp_name-$comp_ver source and signature..."
	if ! run_command curl -f -L "$comp_src" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
		log ERROR "Failed to download $comp_name-$comp_ver source."
		exit 1
	fi
	if ! run_command curl -f -L "$comp_sig" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc"; then
		log ERROR "Failed to download $comp_name-$comp_ver signature."
		exit 1
	fi

	# Проверка GPG подписи для $comp_name-$comp_ver
	log INFO "Verifying GPG signature for $comp_name-$comp_ver..."
	if ! gpg --homedir "$GNUPGHOME" --verify "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc" "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
		log ERROR "GPG signature verification failed for $comp_name-$comp_ver."
		exit 1
	fi

	# Распаковка и установка
	log INFO "Extracting and installing $comp_name-$comp_ver..."
	if ! run_command mkdir -p "$SOURCE_DIR/$comp_name-$comp_ver"; then
		log ERROR "Failed to create source directory for $comp_name-$comp_ver."
		exit 1
	fi
	if ! run_command tar -C "$SOURCE_DIR/$comp_name-$comp_ver" -xvzf "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
		log ERROR "Failed to extract $comp_name-$comp_ver."
		exit 1
	fi
	if ! run_command mkdir -p "$INSTALL_PREFIX/share/gvm/gsad/web/"; then
		log ERROR "Failed to create web directory for $comp_name-$comp_ver."
		exit 1
	fi
	if ! run_command cp -rv "$SOURCE_DIR/$comp_name-$comp_ver"/* "$INSTALL_PREFIX/share/gvm/gsad/web/"; then
		log ERROR "Failed to install $comp_name-$comp_ver web files."
		exit 1
	fi
	log INFO "Completed installation of $comp_name-$comp_ver."
}


# -----------------------------------
# Раздел: Конфигурация системы
# -----------------------------------

# Настраивает права доступа для директорий и бинарников OpenVAS.
adjusting_permissions() {
	log INFO "Adjusting permissions for OpenVAS directories and binaries..."
	for dir in /var/log/gvm; do
		if ! run_command mkdir -p "$dir"; then
			log ERROR "Failed to create directory $dir."
			exit 1
		fi
	done
	for dir in /var/log/gvm; do
		if ! run_command chown -R gvm:gvm "$dir"; then
			log ERROR "Failed to set ownership for $dir."
			exit 1
		fi
		if ! run_command chmod -R g+srw "$dir"; then
			log ERROR "Failed to set permissions for $dir."
			exit 1
		fi
		if [ "$(stat -c %U:%G "$dir")" != "gvm:gvm" ]; then
			log WARN "Directory $dir ownership is not gvm:gvm after setting. Verify permissions."
		fi
	done
	log INFO "Permissions adjusted."
}

# Настраивает systemd-сервисы для компонентов OpenVAS.
setting_up_services_for_systemd() {
	log INFO "Setting up systemd services..."
	# Сервис gsad
	log INFO "Creating gsad systemd service..."
	if ! cat << EOF > "$BUILD_DIR/gsad.service"
[Unit]
Description=Greenbone Security Assistant daemon (gsad)
Documentation=man:gsad(8) https://www.greenbone.net
After=network.target

[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=gsad
RuntimeDirectoryMode=2775
PIDFile=/run/gsad/gsad.pid
ExecStart=/usr/local/sbin/gsad --foreground --listen=0.0.0.0 --port=9392 --http-only --mport="$GVMD_PORT" --mlisten="$GVMD_HOST"
Restart=always
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
EOF
	then
		log ERROR "Failed to create gsad systemd service file."
		exit 1
	fi
	if ! run_command cp -v "$BUILD_DIR/gsad.service" /etc/systemd/system/; then
		log ERROR "Failed to install gsad systemd service."
		exit 1
	fi
	
	log INFO "Reloading systemd daemon..."
	if ! run_command systemctl daemon-reload; then
		log ERROR "Failed to reload systemd daemon."
		exit 1
	fi
	log INFO "Systemd services setup completed."
}

# Запускает и включает сервисы OpenVAS.
start_openvas() {
	log INFO "Starting and enabling OpenVAS services..."
	for service in gsad; do
		if ! run_command systemctl start "$service"; then
			log ERROR "Failed to start $service service."
			exit 1
		fi
		if ! run_command systemctl enable "$service"; then
			log WARN "Failed to enable $service service. Service may not start on boot."
		else
			log INFO "$service service started and enabled."
		fi
	done
	log INFO "OpenVAS services started and enabled."
}

# -----------------------------------
# Раздел: Очистка
# -----------------------------------

# Очищает временные директории, использованные во время установки.
cleanup() {
	log INFO "Очистка временных директорий..."
	if ! rm -rf "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR" 2>/dev/null; then
		log WARN "Не удалось полностью очистить временные директории. Проверьте права доступа."
	fi
	log INFO "Очистка завершена."
}

# Перехватывает ошибки и выполняет очистку при выходе
trap 'log ERROR "Скрипт завершён из-за ошибки."; cleanup' ERR
trap cleanup EXIT


# -----------------------------------
# Раздел: Основное выполнение
# -----------------------------------

# Главная функция для оркестрации процесса установки OpenVAS.
main() {
	log INFO "Starting GSAD machine  installation on $(date '+%Y-%m-%d %H:%M:%S')..."

	# Устанавливаем переменные окружения для установки
	set_environment

	# Устанавливаем необходимые пакеты для OpenVAS
	install_packages

	# Проверяем последние версии компонентов
	check_latest_version

	# Создаем пользователя и группу
	create_gvm_user

	# Создаем директории для исходников, сборки и установки
	create_directories
	
	# Импорт ключа электронной подписи
	import_signing_key

	# Устанавливаем gvm-libs
	build_install_component \
		"gvm-libs" \
		"$GVM_LIBS_VERSION" \
		"-S $SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION -B $BUILD_DIR/gvm-libs -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var"

	# Установка GSA (веб-приложение Greenbone Security Assistant)
	# URL: https://greenbone.github.io/docs/latest/22.4/source-build/index.html#gsa
	build_install_gsa \
		"gsa" \
		"$GSA_VERSION"

	# Установка gsad (веб-сервер для GSA)
	# URL: https://greenbone.github.io/docs/latest/22.4/source-build/index.html#gsad
	build_install_component \
		"gsad" \
		"$GSAD_VERSION" \
		"-S $SOURCE_DIR/gsad-$GSAD_VERSION -B $BUILD_DIR/gsad -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var -DGVMD_RUN_DIR=/run/gvmd -DGSAD_RUN_DIR=/run/gsad -DGVM_LOG_DIR=/var/log/gvm -DLOGROTATE_DIR=/etc/logrotate.d"

	# Настройка прав доступа
	adjusting_permissions

	# Настройка сервисов systemd
	setting_up_services_for_systemd

	# Запуск сервисов Greenbone Community Edition
	start_openvas

	# Очищаем временные директории
	cleanup

	log INFO "GSAD machine installation completed successfully."
}

main


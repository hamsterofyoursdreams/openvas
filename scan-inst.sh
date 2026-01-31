#!/bin/bash
USER="$1"
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
    run_command useradd -r -M -U -G sudo -s /usr/sbin/nologin gvm
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
    ["openvas-smb"]="OPENVAS_SMB_VERSION"
    ["openvas-scanner"]="OPENVAS_SCANNER_VERSION"
    ["ospd-openvas"]="OSPD_OPENVAS_VERSION"
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

    if [ "$component" = "openvas-scanner" ]; then
      export OPENVAS_DAEMON="$comp_ver"
      log INFO "Set OPENVAS_DAEMON=$comp_ver"
    fi
      
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
  run_command echo "Y" | dpkg --configure systemd-timesyncd
  run_command apt install -y --reinstall systemd-timesyncd
    
  if ! run_command apt install --no-install-recommends --assume-yes \
    build-essential curl cmake pkg-config python3 python3-pip gnupg libsnmp-dev; then
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

# Устанавливает зависимости для компонента openvas-smb.
install_openvas_smb_dep() {
  log INFO "Installing openvas-smb dependencies..."

  # Очистка кэша
  run_command apt clean
  run_command apt update
      
  # Требуемые зависимости для openvas-smb
  if ! run_command apt install -y \
    gcc-mingw-w64 libgnutls28-dev libglib2.0-dev libpopt-dev libunistring-dev heimdal-multidev perl-base; then
    log ERROR "Failed to install required dependencies for openvas-smb. Check apt configuration."
    exit 1
  fi
  log INFO "openvas-smb dependencies installed."
}

# Устанавливает зависимости для компонента openvas-scanner.
install_openvas_scanner_dep() {
  log INFO "Installing openvas-scanner dependencies..."
    
  # Очистка кэша
  run_command apt clean
  run_command apt update
      
  # Требуемые зависимости для openvas-scanner
  if ! run_command apt install -y \
    bison libglib2.0-dev libgnutls28-dev libgcrypt20-dev libpcap-dev libgpgme-dev libksba-dev rsync nmap libjson-glib-dev libcurl4-gnutls-dev libbsd-dev krb5-multidev libmagic-dev file; then
    log ERROR "Failed to install required dependencies for openvas-scanner. Check apt configuration."
    exit 1
  fi

  log INFO "openvas-scanner dependencies installed."
}

# Устанавливает зависимости для компонента ospd-openvas.
install_ospd_openvas_dep() {
  log INFO "Installing ospd-openvas dependencies..."
    
  # Очистка кэша
  run_command apt clean
  run_command apt update
      
  # Требуемые зависимости для ospd-openvas
  if ! run_command apt install -y \
    python3 python3-pip python3-setuptools python3-packaging python3-wrapt python3-cffi python3-psutil python3-lxml python3-defusedxml python3-paramiko python3-redis python3-gnupg python3-paho-mqtt; then
    log ERROR "Failed to install required dependencies for ospd-openvas. Check apt configuration."
    exit 1
  fi
  log INFO "ospd-openvas dependencies installed."
}

# Устанавливает зависимости для компонента openvasd.
install_openvasd_dep() {
  log INFO "Installing openvasd dependencies..."
    
  local SCRIPT_DIR="$(cd "$(dirname "${B0%/*}")" && pwd)"
  local RUSTUP_INIT="$SCRIPT_DIR/rustup-init.sh"
    
  # Очистка кэша
  run_command apt clean
  run_command apt update
      
  # Требуемые зависимости для openvasd
  if ! run_command apt install -y \
    pkg-config libssl-dev mosquitto mosquitto-clients; then
    log ERROR "Failed to install required dependencies for openvasd. Check apt configuration."
    exit 1
  fi

  log INFO "Starting mosquitto..."
  if ! run_command systemctl enable --now mosquitto; then
    log ERROR "Failed to start mosquitto."
    exit 1
  fi

  # Устанавливает Rust и Cargo для openvasd
  log INFO "Installing Rust and Cargo for openvasd..."
  # Check if rustc is already installed
  if command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
    log INFO "Rust and Cargo are already installed. Verifying versions..."
    local rustc_version
    rustc_version=$(rustc --version)
    local cargo_version
    cargo_version=$(cargo --version)
    log INFO "Found $rustc_version and $cargo_version"
  else
    # Download and install rustup
    if ! curl -s -L https://raw.githubusercontent.com/hamsterofyoursdreams/rust/main/rustup-init.sh -o /tmp/rustup-init.sh; then
      log ERROR "Failed to download rustup installer. Check network."
      exit 1
    fi
    # Install rustup non-interactively
    if ! sh /tmp/rustup-init.sh -y --no-modify-path; then
      log ERROR "Failed to install Rust and Cargo. Check installation script."
      exit 1
    fi
    # Clean up installer
    rm -f /tmp/rustup-init.sh
    log INFO "Rust and Cargo installed successfully."
  fi

  # Source Cargo environment
  if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
  else
    log ERROR "Cargo environment file not found at $HOME/.cargo/env."
    exit 1
  fi

  # Verify Rust and Cargo installation
  if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
    log ERROR "Rust or Cargo not found after installation. Check PATH or installation."
    exit 1
  fi
  log INFO "Rust and Cargo verified: $(rustc --version), $(cargo --version)"
  log INFO "openvasd dependencies installed."
}

# Устанавливает все необходимые зависимости для компонентов OpenVAS.
install_packages() {
  log INFO "Starting installation of all dependencies..."
  for dep_func in install_common_dep install_gvm_libs_dep install_openvas_smb_dep install_openvas_scanner_dep install_ospd_openvas_dep install_openvasd_dep; do
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

# Импортирует GPG ключ подписи Greenbone для проверки пакетов.
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
  if [ "$comp_name" = "openvas-smb" ] || [ "$comp_name" = "openvas-scanner" ]; then
    local comp_sig="https://github.com/greenbone/$comp_name/releases/download/v$comp_ver/$comp_name-v$comp_ver.tar.gz.asc"
  else
    local comp_sig="https://github.com/greenbone/$comp_name/releases/download/v$comp_ver/$comp_name-$comp_ver.tar.gz.asc"
  fi

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

  log INFO "Successfully built and installed $comp_name-$comp_ver"
}

# Устанавливает ospd-openvas с помощью Python pip.
build_install_opsd() {
  local comp_name=$1
  local comp_ver=$2

  log INFO "Starting installation of $comp_name-$comp_ver..."

  local comp_src="https://github.com/greenbone/ospd-openvas/archive/refs/tags/v$comp_ver.tar.gz"
  local comp_sig="https://github.com/greenbone/ospd-openvas/releases/download/v$comp_ver/ospd-openvas-v$comp_ver.tar.gz.asc"

  # Скачивает и проверяет
  log INFO "Downloading $comp_name-$comp_ver source and signature..."
  if ! run_command curl -f -L "$comp_src" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
    log ERROR "Failed to download $comp_name-$comp_ver source."
    exit 1
  fi
  if ! run_command curl -f -L "$comp_sig" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc"; then
    log ERROR "Failed to download $comp_name-$comp_ver signature."
    exit 1
  fi

  log INFO "Verifying GPG signature for $comp_name-$comp_ver..."
  if ! gpg --homedir "$GNUPGHOME" --verify "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc" "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
    log ERROR "GPG signature verification failed for $comp_name-$comp_ver."
    exit 1
  fi

  # Распаковывает и устанавливает
  log INFO "Extracting and installing $comp_name-$comp_ver..."
  if ! run_command tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
    log ERROR "Failed to extract $comp_name-$comp_ver."
    exit 1
  fi
  if ! run_command cd "$SOURCE_DIR/$comp_name-$comp_ver"; then
    log ERROR "Failed to change to $comp_name-$comp_ver directory."
    exit 1
  fi
  if ! run_command mkdir -p "$INSTALL_DIR/$comp_name"; then
    log ERROR "Failed to create install directory for $comp_name."
    exit 1
  fi
  if ! run_command python3 -m pip install --root="$INSTALL_DIR/$comp_name" --no-warn-script-location .; then
    log ERROR "Failed to install $comp_name-$comp_ver via pip."
    exit 1
  fi
  if ! run_command cp -rv "$INSTALL_DIR/$comp_name"/* /; then
    log ERROR "Failed to copy $comp_name-$comp_ver to system directories."
    exit 1
  fi
  log INFO "Completed installation of $comp_name-$comp_ver."
}

# Устанавливает openvasd и scannerctl с помощью Rust.
build_install_openvasd() {
  local comp_name=$1
  local comp_sub=$2
  local comp_ver=$3

  log INFO "Starting installation of $comp_sub-$comp_ver..."

  local comp_src="https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$comp_ver.tar.gz"
  local comp_sig="https://github.com/greenbone/openvas-scanner/releases/download/v$comp_ver/openvas-scanner-v$comp_ver.tar.gz.asc"

  # Скачивает и проверяет
  log INFO "Downloading $comp_name-$comp_ver source and signature..."
  if ! run_command curl -f -L "$comp_src" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
    log ERROR "Failed to download $comp_name-$comp_ver source."
    exit 1
  fi
  if ! run_command curl -f -L "$comp_sig" -o "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc"; then
    log ERROR "Failed to download $comp_name-$comp_ver signature."
    exit 1
  fi

  log INFO "Verifying GPG signature for $comp_name-$comp_ver..."
  if ! gpg --homedir "$GNUPGHOME" --verify "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz.asc" "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
    log ERROR "GPG signature verification failed for $comp_name-$comp_ver."
    exit 1
  fi

  # Распаковывает и собирает
  log INFO "Extracting and building $comp_sub-$comp_ver..."
  if ! run_command tar -C "$SOURCE_DIR" -xvzf "$SOURCE_DIR/$comp_name-$comp_ver.tar.gz"; then
    log ERROR "Failed to extract $comp_name-$comp_ver."
    exit 1
  fi
  if ! run_command mkdir -p "$INSTALL_DIR/$comp_sub/usr/local/bin"; then
    log ERROR "Failed to create install directory for $comp_sub."
    exit 1
  fi
  if ! run_command cd "$SOURCE_DIR/$comp_name-$comp_ver/rust/src/$comp_sub"; then
    log ERROR "Failed to change to $comp_sub directory."
    exit 1
  fi
  if ! run_command cargo build --release; then
    log ERROR "Failed to build $comp_sub."
    exit 1
  fi
  if ! run_command cd "$SOURCE_DIR/$comp_name-$comp_ver/rust/src/scannerctl"; then
    log ERROR "Failed to change to scannerctl directory."
    exit 1
  fi
  if ! run_command cargo build --release; then
    log ERROR "Failed to build scannerctl."
    exit 1
  fi

  # Устанавливает
  log INFO "Installing $comp_sub and scannerctl..."
  if ! run_command cp -v "../../target/release/$comp_sub" "$INSTALL_DIR/$comp_sub/usr/local/bin/"; then
    log ERROR "Failed to copy $comp_sub binary."
    exit 1
  fi
  if ! run_command cp -v "../../target/release/scannerctl" "$INSTALL_DIR/$comp_sub/usr/local/bin/"; then
    log ERROR "Failed to copy scannerctl binary."
    exit 1
  fi
  if ! run_command cp -rv "$INSTALL_DIR/$comp_sub"/* /; then
    log ERROR "Failed to copy $comp_sub binaries to system directories."
    exit 1
  fi
  log INFO "Completed installation of $comp_sub-$comp_ver."
}

# Устанавливает Python-компонент с помощью pip.
build_install_py() {
  local comp_name=$1

  log INFO "Starting installation of $comp_name..."

  log INFO "Installing $comp_name via pip..."
  if ! run_command mkdir -p "$INSTALL_DIR/$comp_name"; then
    log ERROR "Failed to create install directory for $comp_name."
    exit 1
  fi
  if ! run_command python3 -m pip install --root="$INSTALL_DIR/$comp_name" --no-warn-script-location "$comp_name"; then
    log ERROR "Failed to install $comp_name via pip."
    exit 1
  fi
  if ! run_command cp -rv "$INSTALL_DIR/$comp_name"/* /; then
    log ERROR "Failed to copy $comp_name to system directories."
    exit 1
  fi
  log INFO "Completed installation of $comp_name."
}

# -----------------------------------
# Раздел: Конфигурация системы
# -----------------------------------

# Настраивает Redis для OpenVAS и создает сервис.
perform_system_setup() {
  log INFO "Starting system setup for Redis..."
  if ! run_command apt install -y redis-server; then
    log ERROR "Failed to install redis-server."
    exit 1
  fi
  if [ ! -f "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf" ]; then
    log ERROR "Redis configuration file not found in source directory."
    exit 1
  fi
  if ! run_command cp "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf" /etc/redis/; then
    log ERROR "Failed to copy Redis configuration."
    exit 1
  fi
  if ! run_command chown redis:redis /etc/redis/redis-openvas.conf; then
    log ERROR "Failed to set ownership for Redis configuration."
    exit 1
  fi
  if ! run_command sh -c "echo 'db_address = /run/redis-openvas/redis.sock' >> /etc/openvas/openvas.conf"; then
    log ERROR "Failed to update openvas.conf."
    exit 1
  fi
  if ! run_command systemctl start redis-server@openvas.service; then
    log ERROR "Failed to start redis-server@openvas.service."
    exit 1
  fi
  if ! run_command systemctl enable redis-server@openvas.service; then
    log WARN "Failed to enable redis-server@openvas.service. Service may not start on boot."
  fi
  if ! run_command usermod -aG redis gvm; then
    log ERROR "Failed to add gvm user to redis group."
    exit 1
  fi
  log INFO "Redis setup completed."
}

# Настраивает права доступа для директорий и бинарников OpenVAS.
adjusting_permissions() {
  log INFO "Adjusting permissions for OpenVAS directories and binaries..."
  for dir in /var/lib/notus /var/lib/gvm; do
    if ! run_command mkdir -p "$dir"; then
      log ERROR "Failed to create directory $dir."
      exit 1
    fi
  done
  for dir in /var/lib/gvm /var/lib/openvas /var/lib/notus /var/log/gvm; do
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

# Настраивает GPG для валидации фидов.
feed_validation() {
  log INFO "Setting up feed validation with GPG..."
  if ! run_command curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc; then
    log ERROR "Failed to download Greenbone signing key for feed validation."
    exit 1
  fi
  if ! run_command mkdir -p "$GNUPGHOME"; then
    log ERROR "Failed to create GPG home directory $GNUPGHOME."
    exit 1
  fi
  if ! run_command gpg --import /tmp/GBCommunitySigningKey.asc; then
    log ERROR "Failed to import Greenbone signing key for feed validation."
    exit 1
  fi
  if ! run_command sh -c "echo '8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:' | gpg --import-ownertrust"; then
    log ERROR "Failed to set owner trust for Greenbone signing key."
    exit 1
  fi
  if ! run_command mkdir -p "$OPENVAS_GNUPG_HOME"; then
    log ERROR "Failed to create OpenVAS GPG directory $OPENVAS_GNUPG_HOME."
    exit 1
  fi
  if ! run_command cp -r "$GNUPGHOME"/* "$OPENVAS_GNUPG_HOME"/; then
    log ERROR "Failed to copy GPG keys to $OPENVAS_GNUPG_HOME."
    exit 1
  fi
  if ! run_command chown -R gvm:gvm "$OPENVAS_GNUPG_HOME"; then
    log ERROR "Failed to set ownership for $OPENVAS_GNUPG_HOME."
    exit 1
  fi
  log INFO "Feed validation setup completed."
}

# Настраивает sudo для группы gvm для запуска openvas с повышенными привилегиями.
setting_up_sudo_for_scanning() {
  log INFO "Configuring sudo for gvm group..."
  if grep -Fxq "%gvm ALL = NOPASSWD: /usr/local/sbin/openvas" /etc/sudoers.d/gvm; then
    log INFO "Sudo already configured for gvm group."
  else
    log INFO "Setting up sudoers file for gvm group..."
    if ! run_command sh -c "echo '%gvm ALL = NOPASSWD: /usr/local/sbin/openvas' > /etc/sudoers.d/gvm"; then
      log ERROR "Failed to create sudoers file for gvm."
      exit 1
    fi
    if ! run_command chmod 0440 /etc/sudoers.d/gvm; then
      log ERROR "Failed to set permissions for sudoers file."
      exit 1
    fi
    if ! run_command visudo -c -f /etc/sudoers.d/gvm; then
      log ERROR "Sudoers file validation failed for /etc/sudoers.d/gvm."
      exit 1
    fi
    log INFO "Sudo configuration for gvm group completed."
  fi
}

# Функция скачивания сертификатов сканера
downloads_certs() {
  log INFO "Downloading scan certificates to GVM directories..."
  
  # Создание необходимых директорий
  local dirs=(
    "/var/lib/gvm/CA"
    "/var/lib/gvm/private/CA"
  )
  
  for dir in "${dirs[@]}"; do
    if [ ! -d "$dir" ]; then
      if ! run_command mkdir -p "$dir"; then
        log ERROR "Failed to create directory $dir"
        return 1
      fi
      log INFO "Created directory $dir"
    else
      log INFO "Directory $dir already exists"
    fi
  done
  
  # Копирование cacert.pem
  if ! run_command curl --proto '=https' --tlsv1.2 -s https://raw.githubusercontent.com/hamsterofyoursdreams/openvas/main/certs/cacert.pem -o /var/lib/gvm/CA/cacert.pem; then
    log ERROR "Failed to copy cacert.pem to CA/"
    return 1
  fi

  # Копирование cakey.pem
  if ! run_command curl --proto '=https' --tlsv1.2 -s https://raw.githubusercontent.com/hamsterofyoursdreams/openvas/main/certs/cakey.pem -o /var/lib/gvm/private/CA/cakey.pem; then
    log ERROR "Failed to copy cakey.pem to CA/"
    return 1
  fi

  # Копирование clientcert.pem 
  if ! run_command curl --proto '=https' --tlsv1.2 -s https://raw.githubusercontent.com/hamsterofyoursdreams/openvas/main/certs/clientcert.pem  -o /var/lib/gvm/CA/clientcert.pem; then
    log ERROR "Failed to copy clientcert.pem to CA/"
    return 1
  fi

  # Копирование clientkey.pem
  if ! run_command curl --proto '=https' --tlsv1.2 -s https://raw.githubusercontent.com/hamsterofyoursdreams/openvas/main/certs/clientkey.pem -o /var/lib/gvm/private/CA/clientkey.pem; then
    log ERROR "Failed to copy clientkey.pem to CA/"
    return 1
  fi

  # Копирование servercert.pem 
  if ! run_command curl --proto '=https' --tlsv1.2 -s https://raw.githubusercontent.com/hamsterofyoursdreams/openvas/main/certs/servercert.pem  -o /var/lib/gvm/CA/servercert.pem; then
    log ERROR "Failed to copy servercert.pem to CA/"
    return 1
  fi

  # Копирование serverkey.pem
  if ! run_command curl --proto '=https' --tlsv1.2 -s https://raw.githubusercontent.com/hamsterofyoursdreams/openvas/main/certs/serverkey.pem -o /var/lib/gvm/private/CA/serverkey.pem; then
    log ERROR "Failed to copy serverkey.pem to CA/"
    return 1
  fi
  
  # Установка правильных прав доступа
  if ! run_command chown gvm:gvm /var/lib/gvm/CA/*.pem /var/lib/gvm/private/CA/*.pem; then
    log WARN "Failed to set ownership for scan certificates"
  fi
  
  if ! run_command chmod 644 /var/lib/gvm/CA/*.pem && chmod 600 /var/lib/gvm/private/CA/*.pem; then
    log WARN "Failed to set permissions for scan certificates"
  fi
  
  log INFO "Scan certificates successfully restored to GVM directories"
}

# Синхронизирует фиды.
feed_synchronization() {
  log INFO "Starting feed synchronization..."
  if ! run_command /usr/local/bin/greenbone-feed-sync; then
    log ERROR "Failed to synchronize Greenbone feed."
    exit 1
  fi
  log INFO "Feed synchronization completed."
}

# Запускает и включает сервисы OpenVAS.
start_openvas() {
  log INFO "Starting and enabling OpenVAS services..."
  for service in ospd-openvas openvasd; do
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

# Настраивает systemd-сервисы для компонентов OpenVAS.
setting_up_services_for_systemd() {
  log INFO "Setting up systemd services..."
  
  # ospd-openvas service
  log INFO "Creating ospd-openvas systemd service..."
  if ! cat << EOF > "$BUILD_DIR/ospd-openvas.service"
[Unit]
Description=OSPd Wrapper for the OpenVAS Scanner (ospd-openvas)
Documentation=man:ospd-openvas(8) man:openvas(8)
After=network.target networking.service redis-server@openvas.service openvasd.service
Wants=redis-server@openvas.service openvasd.service
ConditionKernelCommandLine=!recovery

[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=ospd
RuntimeDirectoryMode=2775
PIDFile=/run/ospd/ospd-openvas.pid
ExecStart=/usr/local/bin/ospd-openvas --foreground --unix-socket /run/ospd/ospd-openvas.sock --pid-file /run/ospd/ospd-openvas.pid --log-file /var/log/gvm/ospd-openvas.log --port 9999 --bind-address 0.0.0.0 --lock-file-dir /var/lib/openvas --socket-mode 0o770 --notus-feed-dir /var/lib/notus/advisories
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
  then
    log ERROR "Failed to create ospd-openvas systemd service file."
    exit 1
  fi
  if ! run_command cp -v "$BUILD_DIR/ospd-openvas.service" /etc/systemd/system/; then
    log ERROR "Failed to install ospd-openvas systemd service."
    exit 1
  fi
    
  # openvasd service
  log INFO "Creating openvasd systemd service..."
  if ! cat << EOF > "$BUILD_DIR/openvasd.service"
[Unit]
Description=OpenVASD
Documentation=https://github.com/greenbone/openvas-scanner/tree/main/rust/openvasd
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
RuntimeDirectory=openvasd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/bin/openvasd --mode service_notus --products /var/lib/notus/products --advisories /var/lib/notus/advisories --listening 127.0.0.1:3000
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF
  then
    log ERROR "Failed to create openvasd systemd service file."
    exit 1
  fi
  if ! run_command cp -v "$BUILD_DIR/openvasd.service" /etc/systemd/system/; then
    log ERROR "Failed to install openvasd systemd service."
    exit 1
  fi

  log INFO "Reloading systemd daemon..."
  if ! run_command systemctl daemon-reload; then
    log ERROR "Failed to reload systemd daemon."
    exit 1
  fi
  log INFO "Systemd services setup completed."
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
  log INFO "Starting Scanner machine  installation on $(date '+%Y-%m-%d %H:%M:%S')..."

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

    
  # Установка openvas-smb
  build_install_component \
    "openvas-smb" \
    "$OPENVAS_SMB_VERSION" \
    "-S $SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION -B $BUILD_DIR/openvas-smb -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release"

  # Установка openvas-scanner
  build_install_component \
    "openvas-scanner" \
    "$OPENVAS_SCANNER_VERSION" \
    "-S $SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION -B $BUILD_DIR/openvas-scanner -DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock -DOPENVAS_RUN_DIR=/run/ospd"

  # Установка ospd-openvas
  build_install_opsd \
    "ospd-openvas" \
    "$OSPD_OPENVAS_VERSION"

  # Установка openvasd
  build_install_openvasd \
    "openvas-scanner" \
    "openvasd" \
    "$OPENVAS_DAEMON"

      
  # Устанавливаем greenbone-feed-sync
  build_install_py \
  "greenbone-feed-sync"

  # Выполняем настройки системы
  perform_system_setup
    
  # Настройка прав доступа
  adjusting_permissions

  # Валидация фидов
  feed_validation

  # Настройка sudo для сканирования
  setting_up_sudo_for_scanning

  # Скачивание сертификатов сканера
  downloads_certs

  # Настройка сервисов systemd
  setting_up_services_for_systemd

  # Синхронизация фидов
  feed_synchronization

  # Запуск сервисов Greenbone Community Edition
  start_openvas

  # Очищаем временные директории
  cleanup

  log INFO "Scan machine installation completed successfully."
}

main

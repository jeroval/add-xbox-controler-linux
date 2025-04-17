#!/bin/bash

################################################################################
# xbox_bluetooth_auto_connect_fedora.sh
# Version : 2.0
# Description : Script intelligent et autonome pour connecter automatiquement une
#               manette Xbox Bluetooth sous Fedora.
################################################################################

### CONFIGURATION UTILISATEUR #################################################

XBOX_MAC=""                     # Laisser vide pour détection automatique
XBOX_NAME="Xbox Wireless Controller"
LOG_DIR="$HOME/.local/logs/xbox_bluetooth"
LOG_FILE="$LOG_DIR/$(date '+%Y-%m-%d_%H-%M-%S').log"
SCAN_TIMEOUT=20
SYSTEMD_SERVICE="/etc/systemd/system/xbox-controller-autoconnect.service"
MODPROBE_FILE="/etc/modprobe.d/bluetooth.conf"
MAIN_CONF="/etc/bluetooth/main.conf"

### INITIALISATION ############################################################

mkdir -p "$LOG_DIR"
LOCK_FILE="/tmp/xbox_bluetooth_auto_connect.lock"

if [ -f "$LOCK_FILE" ]; then
  echo "[ERROR] Une instance du script est déjà en cours." | tee -a "$LOG_FILE"
  exit 1
fi

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT

log() {
  level="$1"
  shift
  echo "[$level] $*" | tee -a "$LOG_FILE"
}

### FONCTIONS UTILITAIRES #####################################################

check_dependencies() {
  local deps=(bluetoothctl rfkill systemctl modprobe grep sed awk sleep mkdir tee dnf git)
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      log ERROR "Dépendance manquante : $dep"
      exit 1
    fi
  done

  if ! rpm -q bluez &>/dev/null; then
    log INFO "Installation de bluez..."
    sudo dnf install -y bluez
  fi

  if ! lsmod | grep -q xpadneo; then
    log INFO "Installation de xpadneo..."
    sudo dnf install -y dkms kernel-devel
    git clone https://github.com/atar-axis/xpadneo.git /tmp/xpadneo
    cd /tmp/xpadneo && sudo ./install.sh && cd -
    rm -rf /tmp/xpadneo
  fi
}

configure_main_conf() {
  log INFO "Configuration de /etc/bluetooth/main.conf"
  sudo sed -i '/^\[General\]/,/^\[.*\]/s/^Privacy=.*/Privacy=device/' "$MAIN_CONF" || echo "Privacy=device" | sudo tee -a "$MAIN_CONF"
  sudo sed -i '/^\[General\]/,/^\[.*\]/s/^JustWorksRepairing=.*/JustWorksRepairing=always/' "$MAIN_CONF" || echo "JustWorksRepairing=always" | sudo tee -a "$MAIN_CONF"
  sudo sed -i '/^\[General\]/,/^\[.*\]/s/^FastConnectable=.*/FastConnectable=true/' "$MAIN_CONF" || echo "FastConnectable=true" | sudo tee -a "$MAIN_CONF"
  sudo sed -i '/^\[Policy\]/,/^\[.*\]/s/^AutoEnable=.*/AutoEnable=true/' "$MAIN_CONF" || echo -e "\n[Policy]\nAutoEnable=true" | sudo tee -a "$MAIN_CONF"
  sudo systemctl restart bluetooth
}

disable_ertm_if_needed() {
  if [[ "$(uname -r)" < "5.12" ]]; then
    log INFO "Désactivation de ERTM pour les noyaux < 5.12"
    echo "options bluetooth disable_ertm=Y" | sudo tee "$MODPROBE_FILE"
    sudo modprobe -r bluetooth && sudo modprobe bluetooth
  fi
}

start_bluetooth() {
  sudo rfkill unblock bluetooth
  sudo systemctl start bluetooth
  sudo systemctl enable bluetooth
  log INFO "Service Bluetooth activé."
}

scan_for_controller() {
  log INFO "Recherche de la manette pendant $SCAN_TIMEOUT secondes..."
  bluetoothctl --timeout "$SCAN_TIMEOUT" scan on &>> "$LOG_FILE" &
  local timer=0
  while [ "$timer" -lt "$SCAN_TIMEOUT" ]; do
    result=$(bluetoothctl devices | grep "$XBOX_NAME")
    if [ -n "$result" ]; then
      XBOX_MAC=$(echo "$result" | awk '{print $2}')
      log INFO "Manette détectée : $XBOX_MAC"
      return 0
    fi
    sleep 1
    ((timer++))
  done
  log ERROR "Manette non détectée. Vérifiez qu'elle est en mode appairage."
  return 1
}

pair_and_trust() {
  log INFO "Appairage avec la manette ($XBOX_MAC) ..."
  bluetoothctl <<EOF
agent NoInputNoOutput
default-agent
power on
scan off
pair $XBOX_MAC
trust $XBOX_MAC
connect $XBOX_MAC
EOF
}

add_autoconnect_service() {
  if [ -z "$XBOX_MAC" ]; then
    log WARNING "MAC de la manette inconnue, service non créé."
    return
  fi
  sudo bash -c "cat > $SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Reconnexion automatique de la manette Xbox
After=bluetooth.target
Wants=bluetooth.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bluetoothctl connect $XBOX_MAC

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reexec
  sudo systemctl enable xbox-controller-autoconnect
  log INFO "Service de reconnexion automatique activé."
}

### EXECUTION PRINCIPALE ######################################################

log INFO "====== DÉMARRAGE DU SCRIPT xbox_bluetooth_auto_connect_fedora.sh ======"
check_dependencies
configure_main_conf
disable_ertm_if_needed
start_bluetooth

if [ -z "$XBOX_MAC" ]; then
  scan_for_controller || exit 1
fi

pair_and_trust
add_autoconnect_service

log INFO "====== SCRIPT TERMINÉ AVEC SUCCÈS ======"
exit 0

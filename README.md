# kiosk-setup

Первичная подготовка планшета киоска на чистой Ubuntu Server 24.04: пользователи
root и kiosk, ключ рабочей станции, вход root по SSH, Ethernet по DHCP и минимум
пакетов. Дальше — Ansible с рабочей станции.

На планшете:

```bash
wget https://raw.githubusercontent.com/ManZill/kiosk-setup/main/bootstrap.sh
sudo bash bootstrap.sh          # prod: openssh-server, rsync
sudo bash bootstrap.sh --dev    # стенд: ещё gdb, ping, tcpdump
```

Ключи — `bash bootstrap.sh --help`.

Копия `ansible/bootstrap.sh` из основного репозитория (ADR-0053): правится там,
сюда — только копируется.

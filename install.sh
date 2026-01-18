#!/bin/bash
set -e

# ==============================
# PowerDNS + PowerDNS Admin Kurulum Scripti
# Web Panel: rdns.brnchost.com
# Ubuntu 22.04 / 24.04
# ==============================

DOMAIN="rdns.brnchost.com"
DB_NAME="powerdns"
DB_USER="pdns"
DB_PASS="$(openssl rand -base64 24)"
API_KEY="$(openssl rand -base64 32)"
SECRET_KEY="$(openssl rand -base64 32)"
PDNS_GMYSQL_CONF="/etc/powerdns/pdns.d/pdns.local.gmysql.conf"
PDNS_CONF="/etc/powerdns/pdns.conf"
PDA_DIR="/opt/powerdns-admin"

echo "===== PowerDNS Kurulumu Başlıyor ====="

# 1) Sistem güncelleme
apt update && apt upgrade -y

# 2) MariaDB kurulumu
apt install mariadb-server -y
mysql_secure_installation <<EOF

y
y
y
y
y
y
EOF

# 3) Veritabanı oluştur
mysql -u root <<EOF
CREATE DATABASE ${DB_NAME};
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
EXIT;
EOF

# 4) PowerDNS kurulumu
apt install pdns-server pdns-backend-mysql -y

# 5) Schema import
mysql -u root ${DB_NAME} < /usr/share/pdns-backend-mysql/schema.mysql.sql

# 6) PowerDNS MySQL config
cat > ${PDNS_GMYSQL_CONF} <<EOF
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=${DB_NAME}
gmysql-user=${DB_USER}
gmysql-password=${DB_PASS}
gmysql-dnssec=yes
EOF

# 7) API açma
cat >> ${PDNS_CONF} <<EOF
api=yes
api-key=${API_KEY}
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
EOF

systemctl restart pdns
systemctl enable pdns

# 8) PowerDNS Admin kurulumu
apt install git python3.11 python3.11-venv python3.11-dev libmysqlclient-dev build-essential nginx -y

git clone https://github.com/ngoduykhanh/PowerDNS-Admin.git ${PDA_DIR}
cd ${PDA_DIR}

python3.11 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
pip install gunicorn

cp configs/development.py configs/production.py

# 9) production.py düzenleme
sed -i "s/^SECRET_KEY.*/SECRET_KEY = '${SECRET_KEY}'/" configs/production.py
sed -i "s/^SQLA_DB_USER.*/SQLA_DB_USER = '${DB_USER}'/" configs/production.py
sed -i "s/^SQLA_DB_PASSWORD.*/SQLA_DB_PASSWORD = '${DB_PASS}'/" configs/production.py
sed -i "s/^SQLA_DB_HOST.*/SQLA_DB_HOST = '127.0.0.1'/" configs/production.py
sed -i "s/^SQLA_DB_NAME.*/SQLA_DB_NAME = '${DB_NAME}'/" configs/production.py

export FLASK_CONF=${PDA_DIR}/configs/production.py
export FLASK_APP=${PDA_DIR}/powerdnsadmin/__init__.py
flask db upgrade

# 10) Gunicorn service
cat > /etc/systemd/system/powerdns-admin.service <<EOF
[Unit]
Description=PowerDNS Admin
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=${PDA_DIR}
Environment="FLASK_CONF=${PDA_DIR}/configs/production.py"
Environment="FLASK_APP=${PDA_DIR}/powerdnsadmin/__init__.py"
ExecStart=${PDA_DIR}/venv/bin/gunicorn --workers 3 --bind unix:/run/powerdns-admin.sock --chdir ${PDA_DIR} "powerdnsadmin:create_app()"
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start powerdns-admin
systemctl enable powerdns-admin

# 11) Nginx reverse proxy
cat > /etc/nginx/sites-available/powerdns-admin <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://unix:/run/powerdns-admin.sock;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/powerdns-admin /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# 12) SSL (Let's Encrypt)
apt install certbot python3-certbot-nginx -y
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN}

# 13) Admin kullanıcı oluşturma
source venv/bin/activate
python3 manage.py create-admin <<EOF
admin
admin@${DOMAIN}
Baran1453**
Baran1453**
EOF

echo "===== KURULUM TAMAMLANDI ====="
echo "Panel: https://${DOMAIN}"
echo "DB USER: ${DB_USER}"
echo "DB PASS: ${DB_PASS}"
echo "API KEY: ${API_KEY}"
echo "ADMIN USER: admin"
echo "ADMIN PASS: Baran1453**"

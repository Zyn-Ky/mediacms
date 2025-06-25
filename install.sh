#!/bin/bash
# should be run as root and only on Ubuntu 20/22, Debian 10/11 (Buster/Bullseye) versions!
echo "Welcome to the MediacMS installation!";

if [ `id -u` -ne 0 ]
  then echo "Please run as root"
  exit
fi


while true; do
    read -p "
This script will attempt to perform a system update and install services including PostgreSQL, nginx and Django.
It is expected to run on a new system **with no running instances of any these services**.
This has been tested only in Ubuntu Linux 22 and 24. Make sure you check the script before you continue. Then enter yes or no
" yn
    case $yn in
        [Yy]* ) echo "OK!"; break;;
        [Nn]* ) echo "Have a great day"; exit;;
        * ) echo "Please answer yes or no.";;
    esac
done

apt-get update && apt-get -y upgrade && apt-get install pkg-config python3-venv python3-dev virtualenv redis-server postgresql nginx git gcc vim unzip imagemagick procps libxml2-dev libxmlsec1-dev libxmlsec1-openssl python3-certbot-nginx certbot wget xz-utils -y

install_nvenc_ffmpeg() {
    echo "ffmpeg with NVENC hardware acceleration will be installed"
    #check if nvidia drivers are installed
    if ! command -v nvidia-smi &> /dev/null; then
        echo "NVIDIA drivers are not installed. Please install them first."
        exit 1
    fi

    echo "removing any existing ffmpeg installation"
    apt remove ffmpeg -y
    mkdir -p tmp
    cd tmp
    # install dependency
    apt update
    apt install build-essential yasm cmake libtool libc6 libc6-dev unzip wget -y
    apt install pkg-config libnuma-dev -y
    # install NVIDIA toolkit
    wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb -O tmp/cuda-keyring_1.1-1_all.deb
    apt install .//cuda-keyring_1.1-1_all.deb -y
    apt update
    apt install cuda-toolkit -y 
    cd ..
    grep -q "export LD_LIBRARY_PATH=\"\?/usr/local/cuda/lib64:\${LD_LIBRARY_PATH}\"\|export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH}:/usr/local/cuda/lib64" "$HOME/.bashrc" || \
    echo "export LD_LIBRARY_PATH=\"/usr/local/cuda/lib64:\${LD_LIBRARY_PATH}\"" >> "$HOME/.bashrc" && \
    echo "Added /usr/local/cuda/lib64 to LD_LIBRARY_PATH."
    grep -q "export PATH=\"\?\$PATH:/usr/local/cuda/bin\"\|export PATH=\"\?/usr/local/cuda/bin:\${PATH}\"" "$HOME/.bashrc" || \
    echo "export PATH=\"\$PATH:/usr/local/cuda/bin\"" >> "$HOME/.bashrc" && \
    echo "Appended /usr/local/cuda/bin to PATH."

    source "$HOME/.bashrc"

    nvcc --version || { echo "CUDA toolkit installation failed. Please check your system compatibility."; exit 1; }

    # compile and add NVENC headers to ffmpeg
    git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git tmp/nv-codec-headers
    cd tmp/nv-codec-headers
    make install
    cd ../..
    git clone https://git.ffmpeg.org/ffmpeg.git tmp/ffmpeg
    cd tmp/ffmpeg
    ./configure --enable-nonfree --enable-cuda-nvcc --enable-libnpp --extra-cflags=-I/usr/local/cuda/include --extra-ldflags=-L/usr/local/cuda/lib64 --enable-nvenc --enable-cuvid --enable-nvdec
    make -j$(nproc)
    make install
    ldconfig
    echo "ffmpeg installed to $(which ffmpeg)"

    ffmpeg

    echo "VIDEO_PROCESSOR = 'nvenc'" >> cms/local_settings.py
    exit 0
}
install_ffmpeg() {
    echo "ffmpeg without hardware acceleration will be installed"
    # install ffmpeg without hardware acceleration
    echo "Downloading and installing ffmpeg"
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    mkdir -p tmp
    tar -xf ffmpeg-release-amd64-static.tar.xz --strip-components 1 -C tmp
    cp -v tmp/{ffmpeg,ffprobe,qt-faststart} /usr/local/bin
    rm -rf tmp ffmpeg-release-amd64-static.tar.xz
    echo "ffmpeg installed to $(which ffmpeg)"
    ffmpeg --version

    echo "VIDEO_PROCESSOR = 'cpu'" >> cms/local_settings.py
}

# prompt use hardware acceleration for ffmpeg
while true; do
    read -p "Do you want to install ffmpeg with NVENC hardware acceleration? (y/n) " yn
    case $yn in
        [Yy]* ) echo "Installing ffmpeg with NVENC hardware acceleration"; install_nvenc_ffmpeg; break;;
        [Nn]* ) echo "Installing ffmpeg without hardware acceleration"; install_ffmpeg; break;;
        * ) echo "Please answer yes or no.";;
    esac
done


read -p "Enter portal URL, or press enter for localhost : " FRONTEND_HOST
read -p "Enter portal name, or press enter for 'MediaCMS : " PORTAL_NAME

[ -z "$PORTAL_NAME" ] && PORTAL_NAME='MediaCMS'
[ -z "$FRONTEND_HOST" ] && FRONTEND_HOST='localhost'

echo 'Creating database to be used in MediaCMS'

su -c "psql -c \"CREATE DATABASE mediacms\"" postgres
su -c "psql -c \"CREATE USER mediacms WITH ENCRYPTED PASSWORD 'mediacms'\"" postgres
su -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE mediacms TO mediacms\"" postgres
su -c "psql -d mediacms -c \"GRANT CREATE, USAGE ON SCHEMA public TO mediacms\"" postgres

echo 'Creating python virtualenv on /home/mediacms.io'

cd /home/mediacms.io
virtualenv . --python=python3
source  /home/mediacms.io/bin/activate
cd mediacms
pip install --no-binary lxml,xmlsec -r requirements.txt

SECRET_KEY=`python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'`

# remove http or https prefix
FRONTEND_HOST=`echo "$FRONTEND_HOST" | sed -r 's/http:\/\///g'`
FRONTEND_HOST=`echo "$FRONTEND_HOST" | sed -r 's/https:\/\///g'`

sed -i s/localhost/$FRONTEND_HOST/g deploy/local_install/mediacms.io

FRONTEND_HOST_HTTP_PREFIX='http://'$FRONTEND_HOST

echo 'FRONTEND_HOST='\'"$FRONTEND_HOST_HTTP_PREFIX"\' >> cms/local_settings.py
echo 'PORTAL_NAME='\'"$PORTAL_NAME"\' >> cms/local_settings.py
echo "SSL_FRONTEND_HOST = FRONTEND_HOST.replace('http', 'https')" >> cms/local_settings.py

echo 'SECRET_KEY='\'"$SECRET_KEY"\' >> cms/local_settings.py
echo "LOCAL_INSTALL = True" >> cms/local_settings.py

mkdir logs
mkdir pids
python manage.py migrate
python manage.py loaddata fixtures/encoding_profiles.json
python manage.py loaddata fixtures/categories.json
python manage.py collectstatic --noinput

ADMIN_PASS=`python -c "import secrets;chars = 'abcdefghijklmnopqrstuvwxyz0123456789';print(''.join(secrets.choice(chars) for i in range(10)))"`
echo "from users.models import User; User.objects.create_superuser('admin', 'admin@example.com', '$ADMIN_PASS')" | python manage.py shell

echo "from django.contrib.sites.models import Site; Site.objects.update(name='$FRONTEND_HOST', domain='$FRONTEND_HOST')" | python manage.py shell

chown -R www-data. /home/mediacms.io/
cp deploy/local_install/celery_long.service /etc/systemd/system/celery_long.service && systemctl enable celery_long && systemctl start celery_long
cp deploy/local_install/celery_short.service /etc/systemd/system/celery_short.service && systemctl enable celery_short && systemctl start celery_short
cp deploy/local_install/celery_beat.service /etc/systemd/system/celery_beat.service && systemctl enable celery_beat &&systemctl start celery_beat
cp deploy/local_install/mediacms.service /etc/systemd/system/mediacms.service && systemctl enable mediacms.service && systemctl start mediacms.service

mkdir -p /etc/letsencrypt/live/mediacms.io/
mkdir -p /etc/letsencrypt/live/$FRONTEND_HOST
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/dhparams/
rm -rf /etc/nginx/conf.d/default.conf
rm -rf /etc/nginx/sites-enabled/default
cp deploy/local_install/mediacms.io_fullchain.pem /etc/letsencrypt/live/$FRONTEND_HOST/fullchain.pem
cp deploy/local_install/mediacms.io_privkey.pem /etc/letsencrypt/live/$FRONTEND_HOST/privkey.pem
cp deploy/local_install/dhparams.pem /etc/nginx/dhparams/dhparams.pem
cp deploy/local_install/mediacms.io /etc/nginx/sites-available/mediacms.io
ln -s /etc/nginx/sites-available/mediacms.io /etc/nginx/sites-enabled/mediacms.io
cp deploy/local_install/uwsgi_params /etc/nginx/sites-enabled/uwsgi_params
cp deploy/local_install/nginx.conf /etc/nginx/
systemctl stop nginx
systemctl start nginx

# attempt to get a valid certificate for specified domain

if [ "$FRONTEND_HOST" != "localhost" ]; then
    echo 'attempt to get a valid certificate for specified url $FRONTEND_HOST'
    certbot --nginx -n --agree-tos --register-unsafely-without-email -d $FRONTEND_HOST
    certbot --nginx -n --agree-tos --register-unsafely-without-email -d $FRONTEND_HOST
    # unfortunately for some reason it needs to be run two times in order to create the entries
    # and directory structure!!!
    systemctl restart nginx
else
    echo "will not call certbot utility to update ssl certificate for url 'localhost', using default ssl certificate"
fi

# Generate individual DH params
if [ "$FRONTEND_HOST" != "localhost" ]; then
    # Only generate new DH params when using "real" certificates.
    openssl dhparam -out /etc/nginx/dhparams/dhparams.pem 4096
    systemctl restart nginx
else
    echo "will not generate new DH params for url 'localhost', using default DH params"
fi

# Bento4 utility installation, for HLS

cd /home/mediacms.io/mediacms
wget http://zebulon.bok.net/Bento4/binaries/Bento4-SDK-1-6-0-637.x86_64-unknown-linux.zip
unzip Bento4-SDK-1-6-0-637.x86_64-unknown-linux.zip
mkdir /home/mediacms.io/mediacms/media_files/hls

# last, set default owner
chown -R www-data. /home/mediacms.io/

echo 'MediaCMS installation completed, open browser on http://'"$FRONTEND_HOST"' and login with user admin and password '"$ADMIN_PASS"''

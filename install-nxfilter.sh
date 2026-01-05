#!/bin/sh

# install-nxfilter.sh <version>
# Installs NxFilter DNS filter software on pfSense.

clear
# The latest version of NxFilter:
NXFILTER_VERSION=$1
if [ -z "$NXFILTER_VERSION" ]; then
  echo "NxFilter version not supplied, checking nxfilter.org for the latest version..."
  NXFILTER_VERSION=$(
    curl -sL 'https://nxfilter.org/curver.php' 2>/dev/null
  )

  if ! $(echo "$NXFILTER_VERSION" | egrep -q '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); then
    echo "Fetched version \"$NXFILTER_VERSION\" doesn't make sense"
    echo "If that's correct, run this script again with \"$NXFILTER_VERSION\" as the first argument:  sh install-nxfilter.sh \"$NXFILTER_VERSION\""
    exit 1
  fi

  printf "OK to download and install NxFilter version $NXFILTER_VERSION ? [y/N] " && read RESPONSE
  case $RESPONSE in
    [Yy] ) ;;
    * ) exit 1;;
  esac
fi

NXFILTER_SOFTWARE_URI="http://pub.nxfilter.org/nxfilter-${NXFILTER_VERSION}.zip"
SERVICE_SCRIPT_PATH="/usr/local/etc/rc.d/nxfilter"

# Temporarily enable FreeBSD repository safely
echo "Temporarily enabling FreeBSD repository..."
sed -i '' 's/enabled: no/enabled: yes/' /usr/local/etc/pkg/repos/FreeBSD.conf
sed 's/enabled: no/enabled: yes/' /usr/local/etc/pkg/repos/pfSense.conf > /tmp/pfSense.conf.tmp && \
mv /tmp/pfSense.conf.tmp /usr/local/etc/pkg/repos/pfSense.conf

env ASSUME_ALWAYS_YES=YES pkg update -f

# Stop NxFilter if it's already running
if [ -f "$SERVICE_SCRIPT_PATH" ]; then
  PID=$(ps ax | grep "/usr/local/nxfilter/nxd.jar" | grep -v grep | awk '{ print $1 }')
  if [ ! -z "$PID" ]; then
    echo -n "Stopping the NxFilter service..."
    /usr/sbin/service nxfilter stop
    echo " ok"
  fi
fi

# Make sure nxd.jar isn't still running for some reason
if [ ! -z "$(ps ax | grep "/usr/local/nxfilter/nxd.jar" | grep -v grep | awk '{ print $1 }')" ]; then
  echo -n "Killing nxd.jar process..."
  /bin/kill -15 `ps ax | grep "/usr/local/nxfilter/nxd.jar" | grep -v grep | awk '{ print $1 }'`
  echo " ok"
fi

# If an installation exists, back up configuration:
if [ -d /usr/local/nxfilter/conf ]; then
  echo "Backing up existing NxFilter config..."
  BACKUPFILE=/var/backups/nxfilter-`date +"%Y%m%d_%H%M%S"`.tgz
  /usr/bin/tar -vczf ${BACKUPFILE} /usr/local/nxfilter/conf/cfg.properties /usr/local/nxfilter/db/config.h2.db
fi

# Add the fstab entries required for OpenJDK to persist:
if [ $(grep -c fdesc /etc/fstab) -eq 0 ]; then
  echo -n "Adding fdesc filesystem to /etc/fstab..."
  echo -e "fdesc\t\t\t/dev/fd\t\tfdescfs\trw\t\t0\t0" >> /etc/fstab
  echo " ok"
fi

if [ $(grep -c proc /etc/fstab) -eq 0 ]; then
  echo -n "Adding procfs filesystem to /etc/fstab..."
  mkdir /proc
  echo -e "proc\t\t\t/proc\t\tprocfs\trw\t\t0\t0" >> /etc/fstab
  echo " ok"
fi

# Run mount to mount the two new filesystems:
echo -n "Mounting new filesystems..."
/sbin/mount -a
echo " ok"

# Install OpenJDK JRE and dependencies:
echo "Checking if openjdk17 is already installed..."

INSTALLED_VERSION=$(pkg info -x openjdk17-jre 2>/dev/null | awk '{print $1}' | cut -d'-' -f3)
AVAILABLE_VERSION=$(pkg rquery '%v' openjdk17-jre 2>/dev/null)

if [ "$INSTALLED_VERSION" = "$AVAILABLE_VERSION" ]; then
  echo "openjdk17 version $INSTALLED_VERSION is already installed."
else
  echo "Installing openjdk17 version $AVAILABLE_VERSION..."
  env ASSUME_ALWAYS_YES=YES pkg install -y openjdk17-jre || {
    echo "Failed to install openjdk17. Aborting."
    exit 1
  }
fi

# Restore original repos
echo "Restoring original repos..."
sed -i '' 's/enabled: yes/enabled: no/' /usr/local/etc/pkg/repos/FreeBSD.conf
rm -f /usr/local/etc/pkg/repos/pfSense.conf && ln -s /usr/local/etc/pfSense/pkg/repos/pfSense-repo-0000.conf /usr/local/etc/pkg/repos/pfSense.conf

env ASSUME_ALWAYS_YES=YES pkg update -f

# Switch to a temp directory for the NxFilter download:
cd `mktemp -d -t nxfilter`

echo -n "Downloading v${NXFILTER_VERSION} NxFilter..."
/usr/bin/fetch ${NXFILTER_SOFTWARE_URI}
echo " ok"

# Unpack the archive into the /usr/local directory:
echo -n "Installing NxFilter in /usr/local/nxfilter..."
/bin/mkdir -p /usr/local/nxfilter
/usr/bin/tar zxf nxfilter-${NXFILTER_VERSION}.zip -C /usr/local/nxfilter
echo " ok"

# Create service script on rc.d
echo -n "Creating nxfilter service script in /usr/local/etc/rc.d/ ..."
/bin/cat << "EOF" > $SERVICE_SCRIPT_PATH
#!/bin/sh

# REQUIRE: FILESYSTEMS NETWORKING
# PROVIDE: nxfilter

. /etc/rc.subr

name="nxfilter"
desc="NxFilter DNS filter."
rcvar="nxfilter_enable"
start_cmd="nxfilter_start"
stop_cmd="nxfilter_stop"

pidfile="/var/run/${name}.pid"

nxfilter_start()
{
  if checkyesno ${rcvar}; then
    # check for leftover pid file
    if [ -f $pidfile ]; then
      # check if file contains something
      if `grep -q '[^[:space:]]' < "$pidfile"` ; then
        # check to see if pid from file is actually running, if not remove pid file
        if `cat "$pidfile" | xargs ps -p >/dev/null` ; then
          echo "NxFilter process is already running"
          exit 1
        else
          rm $pidfile
        fi
      else
        rm $pidfile
      fi
    fi 

    echo "Starting NxFilter..."
    /usr/local/nxfilter/bin/startup.sh -d &
    # wait for process to start before adding pid to file
    x=1
    while [ "$x" -le 15 ];
    do
      ps | grep 'nxd.jar' | grep -v grep >/dev/null
      if [ $? -eq 0 ]; then
        break
      fi
      echo -n "."
      sleep 1
      x=$(( x + 1 ))
    done
    echo `ps | grep 'nxd.jar' | grep -v grep | awk '{ print $1 }'` > $pidfile
    echo " OK"   
  fi
}

nxfilter_stop()
{
  if [ -f $pidfile ]; then
    # check if file contains something
    if `grep -q '[^[:space:]]' < "$pidfile"` ; then
      # check to see if pid from file is actually running, if not remove pid file
      if `cat "$pidfile" | xargs ps -p >/dev/null` ; then
        echo "Stopping NxFilter..."
        /usr/local/nxfilter/bin/shutdown.sh &
        while [ `pgrep -F $pidfile 2>/dev/null` ]; do
            echo -n "."
            sleep 1
        done
      fi
      rm $pidfile
      echo "OK stopped";
    else
      echo "NxFilter not running. No PID found."
      rm $pidfile
    fi
  else
    echo "NxFilter not running. No PID file found."
  fi 
}

load_rc_config ${name}
run_rc_command "$1"
EOF
echo " ok"

# add execute permissions
echo -n "Setting execute permissons for scripts..."
chmod +x $SERVICE_SCRIPT_PATH
chmod +x /usr/local/nxfilter/bin/*.sh
echo " ok"

# Add the startup variable to rc.conf.local.
# Eventually, this step will need to be folded into pfSense, which manages the main rc.conf.
# In the following comparison, we expect the 'or' operator to short-circuit, to make sure the file exists and avoid grep throwing an error.
if [ ! -f /etc/rc.conf.local ] || [ $(grep -c nxfilter_enable /etc/rc.conf.local) -eq 0 ]; then
  echo -n "Enabling the NxFilter service..."
  echo "nxfilter_enable=YES" >> /etc/rc.conf.local
  echo " ok"
fi

# Restore the backup configuration:
if [ ! -z "${BACKUPFILE}" ] && [ -f ${BACKUPFILE} ]; then
  echo "Restoring NxFilter config..."
  cp /usr/local/nxfilter/conf /usr/local/nxfilter/conf-`date +%Y%m%d-%H%M`
  /usr/bin/tar -vxzf ${BACKUPFILE} -C /
fi

echo "Running the NxFilter service..."
/usr/sbin/service nxfilter start
echo "All done!"

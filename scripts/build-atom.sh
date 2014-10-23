#!/usr/bin/env bash

cwd=$(pwd)
arch="x64"

# @TODO 0.10.30 must be added to https://github.com/mapbox/node-pre-gyp/blob/master/lib/util/abi_crosswalk.json
# and available in all our node-pre-gyp modules.
node_version="0.10.26"
atom_version="0.16.2"

if [ -z "$1" ]; then
    gitsha="master"
else
    gitsha=$1
fi

if [ -z "$2" ]; then
    platform=$(uname -s | sed "y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/")
else
    platform=$2
fi

atom_arch=$arch
if [ "$platform" == "win32" ]; then
    atom_arch="ia32"
fi

set -e -u
set -o pipefail

if ! which git > /dev/null; then echo "git command not found"; exit 1; fi;
if ! which aws > /dev/null; then echo "aws command not found"; exit 1; fi;
if ! which npm > /dev/null; then echo "npm command not found"; exit 1; fi;
if ! which tar > /dev/null; then echo "tar command not found"; exit 1; fi;
if ! which curl > /dev/null; then echo "curl command not found"; exit 1; fi;
if ! which unzip > /dev/null; then echo "unzip command not found"; exit 1; fi;

build_dir="/tmp/mapbox-studio-$platform-$arch-$gitsha"
shell_url="https://github.com/atom/atom-shell/releases/download/v$atom_version/atom-shell-v$atom_version-$platform-$atom_arch.zip"
shell_file="/tmp/atom-shell-v$atom_version-$platform-$atom_arch.zip"

if [ "$platform" == "darwin" ]; then
    app_dir="/tmp/mapbox-studio-$platform-$arch-$gitsha/Atom.app/Contents/Resources/app"
else
    app_dir="/tmp/mapbox-studio-$platform-$arch-$gitsha/resources/app"
fi

echo "Building bundle in $build_dir"

if [ -d $build_dir ]; then
    echo "Build dir $build_dir already exists"
    exit 1
fi

echo "Downloading atom $shell_url"
curl -Lsfo $shell_file $shell_url
unzip -qq $shell_file -d $build_dir
rm $shell_file

echo "downloading studio"
git clone https://github.com/mapbox/mapbox-studio.git $app_dir
cd $app_dir
git checkout $gitsha
rm -rf $app_dir/.git

echo "updating license"
# Update LICENSE and version files from atom default.
ver=$(node -e "var fs = require('fs'); console.log(JSON.parse(fs.readFileSync('$app_dir/package.json')).version);")
echo $ver > $build_dir/version
cp $app_dir/LICENSE.md $build_dir/LICENSE
mv $build_dir/version $build_dir/version.txt
mv $build_dir/LICENSE $build_dir/LICENSE.txt

echo "running npm install"
BUILD_PLATFORM=$platform npm install --production

# Remove extra deps dirs to save space
deps="node_modules/mbtiles/node_modules/sqlite3/deps
node_modules/mapnik-omnivore/node_modules/gdal/deps
node_modules/mapnik-omnivore/node_modules/srs/deps"
for depdir in $deps; do
    rm -r $app_dir/$depdir
done

# Go through pre-gyp modules and rebuild for target platform/arch.
modules="node_modules/mapnik
node_modules/mbtiles/node_modules/sqlite3
node_modules/mapnik-omnivore/node_modules/srs
node_modules/mapnik-omnivore/node_modules/gdal"
for module in $modules; do
    rm -r $app_dir/$module/lib/binding
    cd $app_dir/$module
    echo "resbuilding $app_dir for $platform $node_version $arch"
    $app_dir/node_modules/.bin/node-pre-gyp install \
        --target_platform=$platform \
        --target=$node_version \
        --target_arch=$arch \
        --fallback-to-build=false
done

cd /tmp

# win32: installer using nsis
if [ $platform == "win32" ]; then
    if ! which makensis > /dev/null; then echo "makensis command not found"; exit 1; fi;
    if ! which signcode > /dev/null; then echo "signcode command not found"; exit 1; fi;
    if ! which expect > /dev/null; then echo "expect command not found"; exit 1; fi;

    # windows code signing
    # uses mono `signcode` and `expect` because signcode prompts for
    # secret key password without option for supplying it otherwise.
    aws s3 cp s3://mapbox/mapbox-studio/certs/authenticode.pvk authenticode.pvk
    aws s3 cp s3://mapbox/mapbox-studio/certs/authenticode.spc authenticode.spc

    function winsign() {
        echo "
            spawn signcode \
            -spc authenticode.spc \
            -v authenticode.pvk \
            -a sha1 -$ commercial \
            -n Mapbox\ Studio \
            -i https://www.mapbox.com/ \
            -t http://timestamp.verisign.com/scripts/timstamp.dll \
            -tr 10 \
            $1

            expect \"Enter password for authenticode.pvk:\"
            send -- \"$2\r\"
            expect eof
            lassign [wait] pid spawnid os_error_flag value
            exit \$value" | expect > /dev/null && echo "Signed $1"
    }

    # sign atom.exe to avoid false positives with antivirus software
    echo "running windows signing on atom.exe"
    winsign $build_dir/atom.exe $WINCERT_PASSWORD
    rm $build_dir/atom.exe.bak

    # curl -Lsfo $build_dir/resources/app/vendor/vcredist_x86.exe http://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x86.exe
    echo "downloading c++ lib "
    curl -Lfo "$build_dir/resources/app/vendor/vcredist_x64.exe" "https://mapnik.s3.amazonaws.com/dist/dev/VS-2014-runtime/vcredist_x64.exe"
    echo "running makensis"
    makensis -V2 $build_dir/resources/app/scripts/mapbox-studio.nsi
    echo "cleaning up after makensis"
    rm -rf $build_dir
    mv /tmp/mapbox-studio.exe $build_dir.exe

    # sign installer
    echo "running windows signing on installer"
    winsign $build_dir.exe $WINCERT_PASSWORD

    # remove cert
    rm -f authenticode.pvk
    rm -f authenticode.spc

    echo "uploading $build_dir.exe"
    aws s3 cp --acl=public-read $build_dir.exe s3://mapbox/mapbox-studio/
    echo "Build at https://mapbox.s3.amazonaws.com/mapbox-studio/$(basename $build_dir.exe)"
    rm -f $build_dir.exe
# darwin: add app resources, zip up
elif [ $platform == "darwin" ]; then
    # Update Info.plist with correct version number.
    sed -i.bak s/VREPLACE/$ver/ $app_dir/scripts/assets/Info.plist

    rm $build_dir/Atom.app/Contents/Resources/atom.icns
    cp $app_dir/scripts/assets/mapbox-studio.icns $build_dir/Atom.app/Contents/Resources/mapbox-studio.icns
    cp $app_dir/scripts/assets/Info.plist $build_dir/Atom.app/Contents/Info.plist
    mv $build_dir/Atom.app "$build_dir/Mapbox Studio.app"

    # Test getting signing key.
    aws s3 cp "s3://mapbox/mapbox-studio/keys/Developer ID Certification Authority.cer" authority.cer
    aws s3 cp "s3://mapbox/mapbox-studio/keys/Developer ID Application: Mapbox, Inc. (GJZR2MEM28).cer" signing-key.cer
    aws s3 cp "s3://mapbox/mapbox-studio/keys/Mac Developer ID Application: Mapbox, Inc..p12" signing-key.p12
    security create-keychain -p travis signing.keychain \
        && echo "+ signing keychain created"
    security import authority.cer -k ~/Library/Keychains/signing.keychain -T /usr/bin/codesign \
        && echo "+ authority cer added to keychain"
    security import signing-key.cer -k ~/Library/Keychains/signing.keychain -T /usr/bin/codesign \
        && echo "+ signing cer added to keychain"
    security import signing-key.p12 -k ~/Library/Keychains/signing.keychain -P "" -T /usr/bin/codesign \
        && echo "+ signing key added to keychain"
    rm authority.cer
    rm signing-key.cer
    rm signing-key.p12

    # update time to try to avoid occaisonal codesign error of "timestamps differ by N seconds - check your system clock"
    sudo ntpdate -u time.apple.com

    # Sign .app file.
    codesign --keychain ~/Library/Keychains/signing.keychain --sign "Developer ID Application: Mapbox, Inc." --deep --verbose --force "$build_dir/Mapbox Studio.app"

    # Verify.
    codesign --verify --deep --verbose=2 "$build_dir/Mapbox Studio.app"

    # Nuke signin keychain.
    security delete-keychain signing.keychain

    # Use ditto rather than zip to preserve code signing.
    ditto -c -k --sequesterRsrc --keepParent --zlibCompressionLevel 9 $(basename $build_dir) $build_dir.zip

    rm -rf $build_dir
    aws s3 cp --acl=public-read $build_dir.zip s3://mapbox/mapbox-studio/
    echo "Build at https://mapbox.s3.amazonaws.com/mapbox-studio/$(basename $build_dir.zip)"
    rm -f $build_dir.zip
# linux: zip up
else
    zip -qr $build_dir.zip $(basename $build_dir)
    rm -rf $build_dir
    aws s3 cp --acl=public-read $build_dir.zip s3://mapbox/mapbox-studio/
    echo "Build at https://mapbox.s3.amazonaws.com/mapbox-studio/$(basename $build_dir.zip)"
    rm -f $build_dir.zip
fi

if [ "$ver" ==  "$(echo $gitsha | tr -d v)" ]; then
    echo $ver > latest
    aws s3 cp --acl=public-read latest s3://mapbox/mapbox-studio/latest
    rm -f latest
    echo "Latest build version at https://mapbox.s3.amazonaws.com/mapbox-studio/latest"
fi

cd $cwd


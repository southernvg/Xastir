# Installed Xastir on MacOS (Mojave)
How to install Xastir on MacOS (Mojave) with brew packages and Xastir source.

## Required Software
### Install XQuartz
X11-org Server for MacOS
#### Download 
https://www.xquartz.org/releases/XQuartz-2.7.11.html

### Install BREW 
The missing package manager for macOS (or Linux) - https://brew.sh/
#### Install
```bash
$ /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
```

### Install XCode
Apple XCode Command Line Utilities - https://developer.apple.com/xcode/

## Install
### Install Brew Packages
```bash
$ brew install subversion gcc pkg-config binutils automake openmotif shapelib pcre libgeotiff graphicsmagick berkeley-db wget curl
```

## Build/Install
### Clone Xastir from Github
```bash
$ git clone https://github.com/Xastir/Xastir.git
```
### Create configuration file and create build directory
```bash
$ ./bootstrap.sh
$ mkdir build
```

### Configure
```bash
$ cd build
$ ../configure
```

### Build
```bash
$ make
```

### Install
```bash
$ sudo make install
```

## Run Xastir
Start XQuartz from the Application directory.  Goto Applications -> Terminal.  In the terminal windows:
```bash
$ xastir
```
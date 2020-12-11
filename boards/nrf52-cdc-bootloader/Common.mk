# Force the Shell to be bash as some systems have strange default shells
SHELL := bash

# Remove built-in rules and variables
# n.b. no-op for make --version < 4.0
MAKEFLAGS += -r
MAKEFLAGS += -R

# The absolute path of the directory containing this `Makefile.common` file.
MAKEFILE_COMMON_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# The absolute path of Tock's root directory.
# This is currently the parent directory of MAKEFILE_COMMON_PATH.
TOCK_ROOT_DIRECTORY := $(dir $(abspath $(MAKEFILE_COMMON_PATH)))

# Common defaults that specific boards can override, but likely do not need to.
TOOLCHAIN ?= llvm
CARGO     ?= cargo
RUSTUP    ?= rustup

# Default location of target directory (relative to board makefile)
# passed to cargo --target_dir
TARGET_DIRECTORY ?= $(TOCK_ROOT_DIRECTORY)target/

# RUSTC_FLAGS allows boards to define board-specific options.
# This will hopefully move into Cargo.toml (or Cargo.toml.local) eventually.
# lld uses the page size to align program sections. It defaults to 4096 and this
# puts a gap between before the .relocate section. `zmax-page-size=512` tells
# lld the actual page size so it doesn't have to be conservative.
RUSTC_FLAGS ?= \
  -C link-arg=-Tlayout.ld \
  -C linker=rust-lld \
  -C linker-flavor=ld.lld \
  -C relocation-model=dynamic-no-pic \
  -C link-arg=-zmax-page-size=512 \
  -C link-arg=-icf=all \

# RISC-V-specific flags.
ifneq ($(findstring riscv32i, $(TARGET)),)
  # NOTE: This flag causes kernel panics on some ARM cores. Since the
  # size benefit is almost exclusively for RISC-V, we only apply it for
  # those targets.
  RUSTC_FLAGS += -C force-frame-pointers=no
endif

# RUSTC_FLAGS_TOCK by default extends RUSTC_FLAGS with options
# that are global to all Tock boards.
#
# We use `remap-path-prefix` to remove user-specific filepath strings for error
# reporting from appearing in the generated binary.
RUSTC_FLAGS_TOCK ?= \
  $(RUSTC_FLAGS) \
  --remap-path-prefix=$(TOCK_ROOT_DIRECTORY)= \

# Disallow warnings for continuous integration builds. Disallowing them here
# ensures that warnings during testing won't prevent compilation from succeeding.
ifeq ($(CI),true)
  RUSTC_FLAGS_TOCK += -D warnings
endif

# The following flags should only be passed to the board's binary crate, but
# not to any of its dependencies (the kernel, capsules, chips, etc.). The
# dependencies wouldn't use it, but because the link path is different for each
# board, Cargo wouldn't be able to cache builds of the dependencies.
#
# Indeed, as far as Cargo is concerned, building the kernel with
# `-C link-arg=-L/tock/boards/imix` is different than building the kernel with
# `-C link-arg=-L/tock/boards/hail`, so Cargo would have to rebuild the kernel
# for each board instead of caching it per board (even if in reality the same
# kernel is built because the link-arg isn't used by the kernel).
#
# Ultimately, this should move to the Cargo.toml, for example when
# https://github.com/rust-lang/cargo/pull/7811 is merged into Cargo.
#
# The difference between `RUSTC_FLAGS_TOCK` and `RUSTC_FLAGS_FOR_BIN` is that
# the former is forwarded to all the dependencies (being passed to cargo via
# the `RUSTFLAGS` environment variable), whereas the latter is only applied to
# the final binary crate (being passed as parameter to `cargo rustc`).
RUSTC_FLAGS_FOR_BIN ?= \
  -C link-arg=-L$(abspath .) \

# http://stackoverflow.com/questions/10858261/abort-makefile-if-variable-not-set
# Check that given variables are set and all have non-empty values, print an
# error otherwise.
check_defined = $(strip $(foreach 1,$1,$(if $(value $1),,$(error Undefined variable "$1"))))

# Check that we know the basics of what we are compiling for.
# `PLATFORM`: The name of the board that the kernel is being compiled for.
# `TARGET`  : The Rust target architecture the kernel is being compiled for.
$(call check_defined, PLATFORM)
$(call check_defined, TARGET)

# Location of target-specific build
TARGET_PATH := $(TARGET_DIRECTORY)$(TARGET)

# If environment variable V is non-empty, be verbose.
ifneq ($(V),)
  Q =
  VERBOSE = --verbose
else
  Q = @
  VERBOSE =
endif

# Ask git what version of the Tock kernel we are compiling, so we can include
# this within the binary. If Tock is not within a git repo then we fallback to
# a set string which should be updated with every release.
export TOCK_KERNEL_VERSION := $(shell git describe --tags --always 2> /dev/null || echo "1.4+")

# Validate that rustup is new enough.
MINIMUM_RUSTUP_VERSION := 1.11.0
RUSTUP_VERSION := $(strip $(word 2, $(shell $(RUSTUP) --version)))
ifeq ($(shell $(TOCK_ROOT_DIRECTORY)tools/semver.sh $(RUSTUP_VERSION) \< $(MINIMUM_RUSTUP_VERSION)), true)
  $(warning Required tool `$(RUSTUP)` is out-of-date.)
  $(warning Running `$(RUSTUP) update` in 3 seconds (ctrl-c to cancel))
  $(shell sleep 3s)
  DUMMY := $(shell $(RUSTUP) update)
endif

# Verify that various required Rust components are installed. All of these steps
# only have to be done once per Rust version, but will take some time when
# compiling for the first time.
LLVM_TOOLS_INSTALLED := $(shell $(RUSTUP) component list | grep 'llvm-tools-preview.*(installed)' > /dev/null; echo $$?)
ifeq ($(LLVM_TOOLS_INSTALLED),1)
  $(shell $(RUSTUP) component add llvm-tools-preview)
endif
ifneq ($(shell $(RUSTUP) component list | grep rust-src),rust-src (installed))
  $(shell $(RUSTUP) component add rust-src)
endif
ifneq ($(shell $(RUSTUP) target list | grep "$(TARGET) (installed)"),$(TARGET) (installed))
  $(shell $(RUSTUP) target add $(TARGET))
endif

# If the user is using the standard toolchain we need to get the full path.
# rustup should take care of this for us by putting in a proxy in .cargo/bin,
# but until that is setup we workaround it.
ifeq ($(TOOLCHAIN),llvm)
  TOOLCHAIN = "$(shell dirname $(shell find `rustc --print sysroot` -name llvm-size))/llvm"
endif

# Set variables of the key tools we need to compile a Tock kernel.
SIZE      ?= $(TOOLCHAIN)-size
OBJCOPY   ?= $(TOOLCHAIN)-objcopy
OBJDUMP   ?= $(TOOLCHAIN)-objdump

# Set additional flags to produce binary from .elf.
# * --strip-sections prevents enormous binaries when SRAM is below flash.
# * --remove-section .apps prevents the .apps section from being included in the
#   kernel binary file. This section is a placeholder for optionally including
#   application binaries, and only needs to exist in the .elf. By removing it,
#   we prevent the kernel binary from overwriting applications.
OBJCOPY_FLAGS ?= --strip-sections -S --remove-section .apps
# This make variable allows board-specific Makefiles to pass down options to
# the Cargo build command. For example, in boards/<custom_board>/Makefile:
# `CARGO_FLAGS += --features=foo` would pass feature `foo` to the top level
# Cargo.toml.
CARGO_FLAGS ?=
# Add default flags to cargo. Boards can add additional options in CARGO_FLAGS
CARGO_FLAGS_TOCK ?= $(VERBOSE) --target=$(TARGET) --package $(PLATFORM) --target-dir=$(TARGET_DIRECTORY) $(CARGO_FLAGS)
# Set the default flags we need for objdump to get a .lst file.
OBJDUMP_FLAGS ?= --disassemble-all --source --section-headers --demangle
# Set default flags for size
SIZE_FLAGS ?=

# Need an extra flag for OBJDUMP if we are on a thumb platform.
ifneq (,$(findstring thumb,$(TARGET)))
  OBJDUMP_FLAGS += --arch-name=thumb
endif

# Check whether the system already has a sha256sum application
# present, if not use the custom shipped one
ifeq (, $(shell sha256sum --version 2>/dev/null))
  # No system sha256sum available
  SHA256SUM := $(CARGO) run --manifest-path $(TOCK_ROOT_DIRECTORY)tools/sha256sum/Cargo.toml -- 2>/dev/null
else
  # Use system sha256sum
  SHA256SUM := sha256sum
endif

# Dump configuration for verbose builds
ifneq ($(V),)
  $(info )
  $(info *******************************************************)
  $(info TOCK KERNEL BUILD SYSTEM -- VERBOSE BUILD CONFIGURATION)
  $(info *******************************************************)
  $(info MAKEFILE_COMMON_PATH = $(MAKEFILE_COMMON_PATH))
  $(info TOCK_ROOT_DIRECTORY  = $(TOCK_ROOT_DIRECTORY))
  $(info TARGET_DIRECTORY     = $(TARGET_DIRECTORY))
  $(info )
  $(info PLATFORM             = $(PLATFORM))
  $(info TARGET               = $(TARGET))
  $(info TOCK_KERNEL_VERSION  = $(TOCK_KERNEL_VERSION))
  $(info RUSTC_FLAGS          = $(RUSTC_FLAGS))
  $(info RUSTC_FLAGS_TOCK     = $(RUSTC_FLAGS_TOCK))
  $(info MAKEFLAGS            = $(MAKEFLAGS))
  $(info OBJDUMP_FLAGS        = $(OBJDUMP_FLAGS))
  $(info OBJCOPY_FLAGS        = $(OBJCOPY_FLAGS))
  $(info CARGO_FLAGS          = $(CARGO_FLAGS))
  $(info CARGO_FLAGS_TOCK     = $(CARGO_FLAGS_TOCK))
  $(info SIZE_FLAGS           = $(SIZE_FLAGS))
  $(info )
  $(info TOOLCHAIN            = $(TOOLCHAIN))
  $(info SIZE                 = $(SIZE))
  $(info OBJCOPY              = $(OBJCOPY))
  $(info OBJDUMP              = $(OBJDUMP))
  $(info CARGO                = $(CARGO))
  $(info RUSTUP               = $(RUSTUP))
  $(info SHA256SUM            = $(SHA256SUM))
  $(info )
  $(info cargo --version      = $(shell $(CARGO) --version))
  $(info rustc --version      = $(shell rustc --version))
  $(info rustup --version     = $(shell $(RUSTUP) --version))
  $(info *******************************************************)
  $(info )
endif

.PRECIOUS: %.elf
# Support rules

# User-facing targets
.PHONY: all
all: release

# `make check` runs the Rust compiler but does not actually output the final
# binary. This makes checking for Rust errors much faster.
.PHONY: check
check:
	$(Q)$(CARGO) check $(VERBOSE) $(CARGO_FLAGS_TOCK)


.PHONY: clean
clean::
	$(Q)$(CARGO) clean $(VERBOSE) --target-dir=$(TARGET_DIRECTORY)

.PHONY: release
release:  $(TARGET_PATH)/release/$(PLATFORM).bin

.PHONY: debug
debug:  $(TARGET_PATH)/debug/$(PLATFORM).bin

.PHONY: debug-lst
debug-lst:  $(TARGET_PATH)/debug/$(PLATFORM).lst

.PHONY: doc
doc: | target
	@# This mess is all to work around rustdoc giving no way to return an
	@# error if there are warnings. This effectively simulates that.
	$(Q)RUSTDOCFLAGS='-Z unstable-options --document-hidden-items -D warnings' $(CARGO) --color=always doc $(VERBOSE) --release --package $(PLATFORM) --target-dir=$(TARGET_DIRECTORY) 2>&1 | tee /dev/tty | grep -q warning && (echo "Warnings detected during doc build" && if [[ $$CI == "true" ]]; then echo "Erroring due to CI context" && exit 33; fi) || if [ $$? -eq 33 ]; then exit 1; fi


.PHONY: lst
lst: $(TARGET_PATH)/release/$(PLATFORM).lst

# Helper rule for showing the TARGET used by this board. Useful when building
# the documentation for all boards.
.PHONY: show-target
show-target:
	$(info $(TARGET))

# Support rules

target:
	@mkdir -p $(TARGET_PATH)

# Cargo outputs an elf file (just without a file extension)
%.elf: %
	$(Q)cp $< $@


%.bin: %.elf
	$(Q)$(OBJCOPY) --output-target=binary $(OBJCOPY_FLAGS) $< $@

%.lst: %.elf
	$(Q)$(OBJDUMP) $(OBJDUMP_FLAGS) $< > $@


$(TOCK_ROOT_DIRECTORY)tools/sha256sum/target/debug/sha256sum:
	$(Q)$(CARGO) build $(VERBOSE) --manifest-path $(TOCK_ROOT_DIRECTORY)tools/sha256sum/Cargo.toml


# Cargo-drivers
# We want to always invoke cargo (yay nested build systems), so these need to
# be phony, which means they can't be pattern rules.

.PHONY: $(TARGET_PATH)/release/$(PLATFORM)
$(TARGET_PATH)/release/$(PLATFORM):
	$(Q)RUSTFLAGS="$(RUSTC_FLAGS_TOCK)" $(CARGO) rustc  $(CARGO_FLAGS_TOCK) --bin $(PLATFORM) --release -- $(RUSTC_FLAGS_FOR_BIN)
	$(Q)$(SIZE) $(SIZE_FLAGS) $@

.PHONY: $(TARGET_PATH)/debug/$(PLATFORM)
$(TARGET_PATH)/debug/$(PLATFORM):
	$(Q)RUSTFLAGS="$(RUSTC_FLAGS_TOCK)" $(CARGO) rustc  $(CARGO_FLAGS_TOCK) --bin $(PLATFORM) -- $(RUSTC_FLAGS_FOR_BIN)
	$(Q)$(SIZE) $(SIZE_FLAGS) $@

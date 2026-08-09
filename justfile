set windows-shell := ["cmd.exe", "/c"]

# Default recipe
default:
    @just --list

# Run the whole continuous integration pipeline
ci:
    zig build ci --summary all

# Compile every artifact without running it
check:
    zig build check --summary all

# Compile every artifact for Windows from any host
check-windows:
    zig build check -Dtarget=x86_64-windows-gnu --summary all

# Compile every artifact for Linux from any host
check-linux:
    zig build check -Dtarget=x86_64-linux-gnu --summary all

# Run every test suite and the formatting check
test:
    zig build test --summary all

# Run the colocated unit tests and the tidy law, optionally filtered: just unit tidy
unit filter="":
    zig build test:unit --summary all -- {{filter}}

# Run the tidy check on its own
tidy:
    zig build test:unit -- tidy

# Check that every source file is formatted
fmt:
    zig build test:fmt

# Format every source file in place
format:
    zig fmt build.zig src

# Run any fuzzer by name: just fuzz gfdi 12345 50000
fuzz name="smoke" seed="" events="":
    zig build fuzz -- {{name}} {{seed}} {{events}}

# Compile the fuzzer without running it
fuzz-build:
    zig build fuzz:build --summary all

# Run every fuzzer briefly with a fixed seed
smoke:
    zig build fuzz:smoke --summary all

# Run the CLI on a Windows or Linux host: just run observe AA:BB:CC:DD:EE:FF
run *args:
    zig build run -- {{args}}

# Clean build artifacts
[unix]
clean:
    rm -rf zig-out .zig-cache

# Clean build artifacts
[windows]
clean:
    if exist zig-out rmdir /s /q zig-out
    if exist .zig-cache rmdir /s /q .zig-cache

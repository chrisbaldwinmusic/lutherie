cmake_minimum_required(VERSION 3.22)

set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")

project(Lutherie VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

option(LUTHERIE_INSTALL_PLUGINS "Copy built plugins into ~/Library/Audio/Plug-Ins" ON)

# JUCE is not stored in the repository: point LUTHERIE_JUCE_DIR at a checkout (build.sh uses ~/Developer/JUCE).
set(LUTHERIE_JUCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../JUCE" CACHE PATH "Path to JUCE")
add_subdirectory("${LUTHERIE_JUCE_DIR}" JUCE)

# The circuit engine: plain C++ with no JUCE in it, shared by the plugin and the tests (and buildable anywhere).
add_library(LutherieCore STATIC
    Source/Core/Circuit.cpp
    Source/Core/Engine.cpp
    Source/Core/Cabinets.cpp
    Source/Core/Rig.cpp)
target_include_directories(LutherieCore PUBLIC Source)
target_compile_options(LutherieCore PRIVATE -O3 -ffp-contract=off)

juce_add_console_app(LutherieTests PRODUCT_NAME "LutherieTests")
target_sources(LutherieTests PRIVATE Tests/Main.cpp Source/Core/CircuitJSON.cpp)
target_compile_definitions(LutherieTests PRIVATE JUCE_STANDALONE_APPLICATION=1 JUCE_USE_CURL=0 JUCE_WEB_BROWSER=0)
target_link_libraries(LutherieTests PRIVATE LutherieCore juce::juce_core)

# The plugin. Until it replaces the Swift version it installs beside it under its own name and codes.
juce_add_plugin(LutherieJUCE
    COMPANY_NAME "Channel Audio"
    BUNDLE_ID "audio.channel.lutherie.juce"
    PLUGIN_MANUFACTURER_CODE Chnl
    PLUGIN_CODE Ltjc
    FORMATS AU VST3 Standalone
    PRODUCT_NAME "Lutherie JUCE"
    IS_SYNTH FALSE
    NEEDS_MIDI_INPUT FALSE
    NEEDS_MIDI_OUTPUT FALSE
    IS_MIDI_EFFECT FALSE
    EDITOR_WANTS_KEYBOARD_FOCUS FALSE
    AU_MAIN_TYPE kAudioUnitType_Effect
    VST3_CATEGORIES Fx Distortion Amp
    COPY_PLUGIN_AFTER_BUILD ${LUTHERIE_INSTALL_PLUGINS}
    MICROPHONE_PERMISSION_ENABLED TRUE
    MICROPHONE_PERMISSION_TEXT "Lutherie plays your guitar through the simulated circuits."
    NEEDS_WEB_BROWSER FALSE
    NEEDS_CURL FALSE)

juce_add_binary_data(LutherieData SOURCES Resources/pedals.json Resources/amps.json)

target_sources(LutherieJUCE PRIVATE
    Source/Core/CircuitJSON.cpp
    Source/Plugin/Session.cpp
    Source/Plugin/PluginProcessor.cpp
    Source/Plugin/PluginEditor.cpp)

target_compile_definitions(LutherieJUCE PUBLIC
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_DISPLAY_SPLASH_SCREEN=0
    JUCE_MODAL_LOOPS_PERMITTED=0)

target_link_libraries(LutherieJUCE
    PRIVATE
        LutherieCore
        LutherieData
        juce::juce_audio_utils
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags)

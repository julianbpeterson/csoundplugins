option(BUILD_JULIAN_OPCODES "Build the Julian opcodes" ON)

if(BUILD_JULIAN_OPCODES)
    make_plugin(julian JulianOpcodes.c)
    target_include_directories(julian PRIVATE ${CSOUND_INCLUDE_DIR})
endif()

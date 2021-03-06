#User-specific source files
list(APPEND PELEC_EXTRA_SOURCES ${CMAKE_SOURCE_DIR}/Exec/RegTests/TG/probdata.f90)
list(APPEND PELEC_EXTRA_SOURCES ${CMAKE_SOURCE_DIR}/Exec/RegTests/TG/Prob_nd.F90)
list(APPEND PELEC_EXTRA_SOURCES ${CMAKE_SOURCE_DIR}/Source/Src_nd/bc_fill_nd.F90)

#Compile-time options for executable
set(PELEC_DIM 2)
set(PELEC_ENABLE_EB OFF)
set(PELEC_ENABLE_MASA OFF)
set(PELEC_ENABLE_REACTIONS OFF)
set(PELEC_ENABLE_MOL OFF)
set(PELEC_ENABLE_PARTICLES OFF)
set(PELEC_EOS_MODEL GammaLaw)
set(PELEC_REACTIONS_MODEL Null)
set(PELEC_TRANSPORT_MODEL Constant)

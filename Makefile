# makefile for TABI-2spheres
#F90= ifort
#flag= -fast -c  
F90 = gfortran
flag= -O2 -c 
tabipb: var_modules.o treecode3d_pb.o main.o readin.o dgmres_dep.o
	$(F90)  -o tabipb *.o 
var_modules.o:	src/var_modules.f90
	$(F90) $(flag) src/var_modules.f90
main.o:		src/main.f90
	$(F90) $(flag) src/main.f90
readin.o:	src/readin.f90
	$(F90) $(flag) src/readin.f90
treecode3d_pb.o:	src/treecode3d_pb.f
	$(F90) $(flag) src/treecode3d_pb.f
dgmres_dep.o:	src/dgmres_dep.f
	$(F90) $(flag) src/dgmres_dep.f
molecule.mod:   src/var_modules.f90
	$(F90) $(flag) src/var_modules.f90
comdata.mod:   src/var_modules.f90
	$(F90) $(flag) src/var_modules.f90
bicg.mod:   	src/var_modules.f90
	$(F90) $(flag) src/var_modules.f90
treecode.mod:	src/var_modules.f90
	$(F90) $(flag) src/var_modules.f90
treecode3d_procedures.mod:	src/treecode3d_pb.f
	$(F90) $(flag) src/treecode3d_pb.f
clean_temp:
	rm *.o *.mod
clean: 
	rm *.o *.mod tabipb surface_potential.dat

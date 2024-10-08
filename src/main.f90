! This program solves poisson-boltzmann equation with the following treatment
! 1. Well-conditioned Boundary Intergral Formulation derived by Juff et. al
! 2. icosahedron grid for two spheres with mutiple charges inside
! 3. Simply the one-particle-per-element treecode as what Lu has done with FMM-PB
! 4. Preconditioning: Diagnal Scaling
! 5. using flat triangle area (curved area gives similar accuracy)
! 6. Singularity-subtraction is not included (it has only been done for Poisson)

program TABIPB 
use molecule
use comdata
use bicg
use treecode
use treecode3d_procedures
implicit double precision(a-h,o-z)
real*8 r0(3), Pxyz(3), err_surf(10,6), err_reaction(10,6), err_reaction_rel(10,6),diff(3)
real*8 pi,one_over_4pi, center(3), kappa2
character(100) fhead
external MATVEC, MSOLVE

common // pi,one_over_4pi

! read in the command line args
integer :: i, num_args
character(len=100) :: arg
character(len=100) :: usr_data_in
character(len=100) :: sphere_dir

call getarg(0, arg)
num_args = command_argument_count()
if (num_args /= 2) then
    write(*,*) 'Usage: ./tabipb usr_data_in sphere_dir'
    stop
endif

call getarg(1, arg)
usr_data_in = trim(arg)
call getarg(2, arg)
sphere_dir = trim(arg)
! read in the command line args

open(101,file=usr_data_in)
READ(101,*,IOSTAT = MEOF) fhead, eps0  !the dielectric constant in molecule
READ(101,*,IOSTAT = MEOF) fhead, eps1  !the dielectric constant in solvent
READ(101,*,IOSTAT = MEOF) fhead, bulk_strength !ion_strength with units (M)$I=\sum\limits_{i=1}^nc_iz_i^2$
READ(101,*,IOSTAT = MEOF) fhead, den   ! the number of level of subdivions for the icosahedron grid
READ(101,*,IOSTAT = MEOF) fhead, order !The order of taylor expansion in treecode
READ(101,*,IOSTAT = MEOF) fhead, maxparnode !maximum particles per leaf in treecode
READ(101,*,IOSTAT = MEOF) fhead, theta !MAC, rc/R<MAC, the bigger MAC, the more treecode
close(101)


!???????????????????????????????????????????????????????????????
fname='oneb'
imd=2 !gan: now it is fixed to be 2

!GMRES
thresh=1.d-20
itol=2
itmax=1000000
tol=1.d-6
!Others
pi=acos(-1.d0)
one_over_4pi=0.25d0/pi
kappa2=8.430325455*bulk_strength/eps1     !kappa2 in 300K
kappa=sqrt(kappa2)                        !kappa
para=332.0716                          !332.0716 in Kcal/mol unit
eps=eps1/eps0;
call cpu_time(cpu1)

call readin(sphere_dir)
!write(*,*), tr_area(1)

!print *,'check location',real(sptpos(:,700)),real(sptpos(:,1980))
print *,'Begin to form linear algebraic matrix...'

call cpu_time(cpu2)


! write the discritized integral equation
call form_matrix

print *,'Begin to initialize treecode...'
call treecode_initialization

call cpu_time(cpu23)
print *,'it takes ',cpu23-cpu2,'seconds to form the matrix'

! To solve by GMRES
ndim=2*nface
print *,'Begin to allocate varibles for the solver...'

allocate(sb(ndim),sx(ndim),STAT=jerr)
if (jerr .ne. 0) then
    write(*,*) 'Error allocating sb and sx'
endif

! setup the parameters of the GMRES solver
MAXL=10		! Maximum dimension of Krylov subspace in which X - X0 is to be found
LRGW=1 + ndim*(MAXL+6) + MAXL*(MAXL+3)		! Length of the double precision workspace, RGWK.
JSCAL=0		! Flag indicating whether the scaling arrays SB and SX are to be used
JPRE=-1		! Flag indicating whether preconditioning is being used
NRMAX=10	! Maximum number of restarts of the Krylov iteration
LIGW=20
MLWK=LIGW	! Required minimum length of RGWK array
NMS=0		! The total number of calls to MSOLVE
ISYM=0		! If the symmetric matrix is stored only in half way
!lenw =  10*ndim; leniw = 10*ndim 
lenw =  10; leniw = 10 

allocate(RGWK(LRGW), IGWK(LIGW), RWORK(lenw), IWORK(leniw), STAT=jerr)
if (jerr .ne. 0) then
	Write(*,*) 'Error allocating RGWK, IGWK, RWORK, IWORK, jerr= ', jerr 
	write(*,*) 'LRGW=',LRGW,'LIGW=',LIGW,'lenw= ',lenw,'leniw=', leniw
	stop
endif
RGWK=0.d0;	IGWK=0; RWORK=0.d0;	IWORK=0
IGWK(1:7)=(/MAXL, MAXL, JSCAL, JPRE, NRMAX, MLWK, NMS/)


print *,'Begin to call the solver...'
call DGMRES(	ndim, bvct, xvct, MATVEC, MSOLVE, ITOL, TOL, ITMAX, & 
				ITER, ERR, IERR, 0, SB, SX, RGWK, LRGW, IGWK, LIGW, RWORK, IWORK)

print *,'err=',err,'ierr=',ierr,'iter=',iter


call cpu_time(cpu3)

! Calculate the potential at a specific point for solvation and Coulombic energy
soleng=0.d0; soleng_exa=0.d0; couleng=0.d0; ptl_err_max=0.d0
print *,'nchr= ',nchr
do iatm=1,nchr
    r0=chrpos(:,iatm)
    ! calculate solvation energy
    if ((imd .ge. 1) .and. iflag_steric_clashes==0) then
        call potential_molecule_mdomains(r0, ptl,iatm)
    else
        call potential_molecule(r0, ptl,0,ptl_err)
        if (ptl_err_max<ptl_err) ptl_err_max=ptl_err
    endif 
    soleng=soleng+atmchr(iatm)*ptl


! calculate Coulombic energy
    if ((imd .ge. 1) .and. iflag_steric_clashes==0) then ! no inter-domain interactions
        if (iatm .le. nchr1) then
            do jatm=iatm+1,nchr1
                diff=r0-chrpos(:,jatm)
                dist=sqrt(dot_product(diff,diff))
                couleng=couleng+1/eps0/dist*atmchr(iatm)*atmchr(jatm)
                !print *,i,j,dist,1/eps0/dist*atmchr(iatm)*atmchr(jatm)*para
            enddo
        else
            do jatm=iatm+1,nchr 
                diff=r0-chrpos(:,jatm)
                dist=sqrt(dot_product(diff,diff))
                couleng=couleng+1/eps0/dist*atmchr(iatm)*atmchr(jatm)
                !print *,i,j,dist,1/eps0/dist*atmchr(iatm)*atmchr(jatm)*para
            enddo
        endif    
    else    ! include inter-domain interactions
        do jatm=iatm+1,nchr
            diff=r0-chrpos(:,jatm)
            dist=sqrt(dot_product(diff,diff))
            couleng=couleng+1/eps0/dist*atmchr(iatm)*atmchr(jatm)
            !print *,i,j,dist,1/eps0/dist*atmchr(iatm)*atmchr(jatm)*para
        enddo
    endif
enddo
soleng=soleng*0.5d0*para*4*pi
couleng=couleng*para
print *,'error between Der. and nDer. =', ptl_err_max
print *,'Coulombic energy=:' ,couleng, ' kcal/mol'
print *,'Solvation energy=:' ,soleng, ' kcal/mol'
print *,'-----Free energy=:', couleng+soleng, ' kcal/mol '

!call output_potential_centroid  !output potential at centriod
call output_potential           !output potential at vertices (can be visualized in VMD)

open(10,file='energy.dat')
write (10,*) (couleng+soleng)

call cpu_time(cpu4)
print *,'setup cpu=', real(cpu2-cpu1)
print *,'solving cpu=', real(cpu3-cpu2)
print *,'cpu for computing solvation energy=',real(cpu4-cpu3)
print *,'Total cpu= ', real(cpu4-cpu1)

print *,'deallocating memories...'
print *,'all done, thank you for using tabipb!'
!-------------------------------------------------------------------------------
! deallocate memory
deallocate(bvct, xvct, stat=ierr)
if (ierr .ne. 0) then
    write(*,*) 'Error deallocating bvct, xvct'
    stop
endif

deallocate(tr_xyz,tr_q,tchg,schg,tr_area,kk,der_cof, stat=ierr)
if (ierr .ne. 0) then
    write(*,*) 'Error deallocating tr_xyz,tr_q,tchg,schg,tr_area,kk'
    stop
endif


deallocate(SB,SX, RGWK, IGWK, RWORK, IWORK, stat=ierr)
if (ierr .ne. 0) then
    write(*,*) 'Error deallocating SB,SX, RGWK, IGWK, RWORK, IWORK'
    stop
endif 

deallocate(atmpos,atmrad,atmchr,chrpos, stat=ierr)
if (ierr .ne. 0) then
    write(*,*) 'Error deallocating atmpos,atmrad,atmchr,chrpos'
    stop
endif 

DEALLOCATE(x,y,z,q,orderind,STAT=ierr)
IF (ierr .NE. 0) THEN
    WRITE(*,*) 'Error deallocating x, y, z, q, or orderind!'
    STOP
END IF

DEALLOCATE(SPTPOS, SPTNRM, NATMAFF, NSFTYPE, NVERT, MFACE, STAT= ierr)
IF (ierr .NE. 0) THEN
    WRITE(*,*) 'Error deallocating SPTPOS, SPTNRM, NATMAFF, NSFTYPE, NVERT, MFACE !'
    STOP
END IF

DEALLOCATE(cf, cf1, cf2, cf3, a, b,STAT=ierr)
IF (ierr .NE. 0) THEN
    WRITE(*,*) 'Error allocating Taylor variables cf, cf1, cf2, cf3, a, b ! '
    STOP
END IF

DEALLOCATE(orderarr,STAT=ierr)
IF (ierr .NE. 0) THEN
    WRITE(6,*) 'Error deallocating copy variables orderarr! '
    STOP
END IF

end program TABIPB 

!###########################################################################
!-----------------------------------------------
Subroutine output_potential_centroid
use comdata
use molecule
use treecode
use treecode3d_procedures
implicit none
integer i,j,k,jerr,nface_vert
real*8 tot_length,loc_length,aa(3),pi,para_temp,one_over_4pi,phi_star


common // pi,one_over_4pi

para_temp=para*4*pi

xvct=xvct*para_temp

print *,'The max and min potential and normal derivatives on elements are: '
write(*,*) 'potential', maxval(xvct(1:nface)),minval(xvct(1:nface)) 
write(*,*) 'norm derv', maxval(xvct(nface+1:2*nface)),minval(xvct(nface+1:2*nface)) 

open(10,file='surface_potential.dat')
write (10,*) nspt,nface

do i=1,nface
	write(10,'(i10,6f12.6,3f20.10)') i, tr_xyz(:,i), tr_q(:,i), xvct(i), xvct(nface+i), tr_area(i)
enddo


End
!###########################################################################
!-----------------------------------------------
Subroutine output_potential
use comdata
use molecule
use treecode
use treecode3d_procedures
implicit none
integer, dimension(:,:), allocatable :: ind_vert
real*8, dimension(:,:), allocatable :: vert_ptl,xyz_temp  
integer i,j,k,jerr,nface_vert
real*8 tot_length,loc_length,aa(3),pi,para_temp,one_over_4pi,phi_star


common // pi,one_over_4pi

nface_vert=15 !To my acknowlege, one vertex could have been involved in at most 11 triangles, 15 is safe
allocate(xtemp(2*numpars),ind_vert(nface_vert,nspt),vert_ptl(2,nspt),xyz_temp(3,numpars),STAT=jerr)
if (jerr .ne. 0) then
    write(*,*) 'Error allocating xtemp, ind_vert, vert_ptl, xyz_temp'
endif
xtemp=0.d0; ind_vert=0; xyz_temp=0.d0; vert_ptl=0.d0
para_temp=para*4*pi


do i=1,numpars
  xtemp(orderarr(i))=xvct(i)           !put things back
  xtemp(orderarr(i)+numpars)=xvct(i+numpars)
  xyz_temp(:,orderarr(i))=tr_xyz(:,i)  
enddo
xvct=xtemp  
tr_xyz=xyz_temp


do i=1,numpars
    do j=1,3
        do k=1,nface_vert-1
            if (ind_vert(k,nvert(j,i)) == 0) then
                ind_vert(k,nvert(j,i)) = i
                ind_vert(nface_vert,nvert(j,i)) = ind_vert(nface_vert,nvert(j,i)) + 1
                goto 1022
            endif
        enddo 
        1022 continue
    enddo
enddo

do i=1,nspt
    tot_length=0.d0 
    do j=1,ind_vert(nface_vert,i)
        aa=tr_xyz(:,ind_vert(j,i))-sptpos(:,i) 
        loc_length=sqrt(dot_product(aa,aa)) !distance between vertices and centroid

        !vert_ptl(1,i)=vert_ptl(1,i)+xvct(ind_vert(j,i))
        !vert_ptl(2,i)=vert_ptl(2,i)+xvct(ind_vert(j,i)+numpars)
        vert_ptl(1,i)=vert_ptl(1,i)+1.d0/loc_length*xvct(ind_vert(j,i))
        vert_ptl(2,i)=vert_ptl(2,i)+1.d0/loc_length*xvct(ind_vert(j,i)+numpars)
        tot_length=tot_length+1.d0/loc_length
    enddo
    !vert_ptl(:,i)=vert_ptl(:,i)/ind_vert(nface_vert,i)
    vert_ptl(:,i)=vert_ptl(:,i)/tot_length
    
    !compute free space induced potentials
    !phi_star=0.d0
    !do j=1,natm
    !    aa=atmpos(:,j)-sptpos(:,i)
    !    loc_length=sqrt(dot_product(aa,aa)) !distance between vertices and charge center 
    !    phi_star=phi_star+atmchr(j)/loc_length 
    !enddo
    !phi_star=phi_star*one_over_4pi !1/4pi/r
    !vert_ptl(1,i)=vert_ptl(1,i)+phi_star    
enddo

xvct=xvct*para_temp
vert_ptl=vert_ptl*para_temp

print *,'The max and min potential and normal derivatives on elements are: '
write(*,*) 'potential', maxval(xvct(1:nface)),minval(xvct(1:nface)) 
write(*,*) 'norm derv', maxval(xvct(nface+1:2*nface)),minval(xvct(nface+1:2*nface)) 

print *,'The max and min potential and normal derivatives on vertices are: '
write(*,*) 'potential', maxval(vert_ptl(1,1:nspt)),minval(vert_ptl(1,1:nspt)) 
write(*,*) 'norm derv', maxval(vert_ptl(2,1:nspt)),minval(vert_ptl(2,1:nspt)) 

open(10,file='surface_potential.dat')
write (10,*) nspt,nface

do i=1,nspt
	write(10,'(i10,6f12.6,2f20.10)') i, sptpos(:,i), sptnrm(:,i), vert_ptl(:,i)
enddo

do i=1,nface
	write(10,*) nvert(:,i) 
enddo
close(10)

deallocate(xtemp,ind_vert, vert_ptl, xyz_temp, STAT=jerr)
if (jerr .ne. 0) then
    write(*,*) 'Error deallocating xtemp, ind_vert, vert_ptl, xyz_temp'
endif


End

!--------------------------------------------------------------------------
subroutine treecode_initialization
use molecule
use bicg
use comdata
use treecode
use treecode3d_procedures
implicit none

real*8 pi, one_over_4pi
common // pi,one_over_4pi

! local variables

INTEGER :: level,ierr,err,i,j,k,mm,nn,idx,ijk(3)

! variables needed for cpu time

REAL*8 :: totaltime,timetree
real*8, dimension(:), allocatable:: temp_a,temp_b
real*8, dimension(:,:), allocatable:: temp_q


allocate(kk(3,16), der_cof(0:order,0:order,0:order,16), STAT=ierr)	
if (ierr .ne. 0) then
	Write(*,*) 'Error allocating auxilary Taylor coefficients kk and der_ncf'
	stop
endif

! The adjustment of k for the recurrance relation 
kk(:,1)=(/0,0,0/);        ! Original Kernel

kk(:,2)=(/1,0,0/);        ! 1st Order Derivative:	partial x
kk(:,3)=(/0,1,0/);        !		                    partial y           
kk(:,4)=(/0,0,1/);        !                         partial z

kk(:,5)=(/1,0,0/);        !							x
kk(:,6)=(/0,1,0/);    	  !							y
kk(:,7)=(/0,0,1/);    	  !							z

kk(:,8)=(/2,0,0/);        ! 2nd Order Drivative:	partial xx						
kk(:,9)=(/1,1,0/);    	  !									xy
kk(:,10)=(/1,0,1/);       !									xz
kk(:,11)=(/1,1,0/);		  !									yx
kk(:,12)=(/0,2,0/);		  !									yy
kk(:,13)=(/0,1,1/);		  !									yz
kk(:,14)=(/1,0,1/);		  !									zx
kk(:,15)=(/0,1,1/);		  !									zy
kk(:,16)=(/0,0,2/);		  !									zz


! The adjustment of der_cof for the recurrance relation
der_cof=1.d0

DO idx=1,16
    DO k=0,order
        DO j=0,order-k
            DO i=0,order-k-j
                ijk=(/i,j,k/)
                DO mm=1,3
                    IF (kk(mm,idx) .ne. 0) THEN
                        DO nn=1,kk(mm,idx)
                            der_cof(i,j,k,idx)=der_cof(i,j,k,idx)*(ijk(mm)+nn)
                        ENDDO
                    ENDIF
                ENDDO
            ENDDO
         ENDDO
     ENDDO
ENDDO

der_cof=der_cof*one_over_4pi
numpars=nface

ALLOCATE(x(numpars),y(numpars),z(numpars),q(numpars),orderind(numpars),STAT=err)
IF (err .NE. 0) THEN
    WRITE(6,*) 'Error allocating x, y, z, q, or orderind!'
    STOP
END IF


allocate(temp_a(numpars),temp_b(2*numpars),temp_q(3,numpars), STAT=err)
IF (err .NE. 0) THEN
    WRITE(6,*) 'Error allocating temp_a, temp_b, temp_q!'
    STOP
END IF

      
x=tr_xyz(1,:)
y=tr_xyz(2,:)
z=tr_xyz(3,:)
q=1.d0


! Call SETUP to allocate arrays for Taylor expansions
! and setup global variables. Also, copy variables into global copy arrays. 
CALL SETUP(x,y,z,q,numpars,order,iflag,xyzminmax)

! nullify pointer to root of tree (TROOT) and create tree
NULLIFY(troot)  

! creating tree

level=0
minlevel=50000
maxlevel=0

WRITE(6,*) ' '
WRITE(6,*) 'Creating tree for ',numpars,' particles with max ', maxparnode, ' per node...'


CALL CPU_TIME(timebeg)
CALL CREATE_TREE(troot,1,numpars,x,y,z,q,maxparnode,xyzminmax,level,numpars)

temp_a=tr_area
temp_b=bvct
temp_q=tr_q


do i=1,numpars
  tr_area(i)=temp_a(orderarr(i))
  tr_q(:,i)=temp_q(:,orderarr(i))
  bvct(i)=temp_b(orderarr(i))
  bvct(i+numpars)=temp_b(orderarr(i)+numpars)
  tr_xyz(:,i)=(/x(i),y(i),z(i)/)
enddo


CALL CPU_TIME(timeend)
totaltime=timeend-timebeg
WRITE(6,*) 'Time to create tree (secs):',totaltime      
      
deallocate(temp_a,temp_b,temp_q, STAT=err)
IF (err .NE. 0) THEN
    WRITE(6,*) 'Error deallocating temp_a, temp_b, temp_q!'
    STOP
END IF
End subroutine



!----------------------------------
subroutine MATVEC(N, XX, bb)
use bicg
use molecule
use comdata
!use treecode
use treecode3d_procedures
implicit double precision(a-h,o-z)
integer N
real*8 xx(N),bb(N),timebeg,timeend

!call cpu_time(timebeg)
if (sum(abs(xx))<1.d-10) goto 1022
CALL TREE_COMPP_PB(troot,kappa,eps,xx)
1022 bb=xx
!call cpu_time(timeend)
!print *,'time to compute AX=: ',timeend-timebeg 
CALL REMOVE_MMT(troot)

return
end subroutine

!-------------------------------------
subroutine MSOLVE(N, R, Z, NELT, IA, JA, A, ISYM, RWORK, IWORK)
use molecule
implicit double precision(a-h,o-z)
real*8 R(N),Z(N),A(N*N),RWORK(*)
integer IA(N*N), JA(N*N), IWORK
scale1=0.5d0*(1.d0+eps)
scale2=0.5d0*(1.d0+1.d0/eps)
Z(1:N/2)=R(1:N/2)/scale1
Z((N/2+1):N)=R((N/2+1):N)/scale2
end subroutine

!-----------------------------------
! input the data into the matrix
subroutine form_matrix
use molecule
use comdata
use treecode
implicit double precision(a-h,o-z)
integer idx(3), istag, NGR
real*8 r0(3), v0(3),v(3,3), r(3,3), r1(3), v1(3), uv(2,10), x10(3,10),v10(3,10),rr(3), diff(3), dist

common // pi,one_over_4pi

! tr_xyz: The position of the particles on surface
! tr_q:	  The normail direction at the particle location
! bvct:	  The right hand side of the pb equation in BIM form
! xvct:	  The vector composed of potential and its normal derivative
! tchg:	  Charges on Target particles
! schg:   Charges on Source particles
! tr_area: the triangular area of each element
allocate(tr_xyz(3,nface),tr_q(3,nface), bvct(2*nface), xvct(2*nface))
allocate(tchg(nface,16,2),schg(nface,16,2))
tr_xyz=0.d0;	tr_q=0.d0;	bvct=0.d0;	xvct=0.d0
tchg=0.d0;		schg=0.d0;

 
do i=1,nface    ! for phi on each element
    idx=nvert(1:3,i) ! vertices index of the specific triangle
    r0=0.d0;    v0=0.d0
    do k=1,3 
        r0=r0+1.d0/3.d0*sptpos(1:3,idx(k))	!centriod
        v0=v0+1.d0/3.d0*sptnrm(1:3,idx(k))	
	    r(:,k)=sptpos(1:3,idx(k))
	    v(:,k)=sptnrm(1:3,idx(k))
    enddo

!write(*,*) r0, v0

    ! Way 1: normlize the midpoint v0
    v0=v0/sqrt(dot_product(v0,v0))
!print *, natm1, natm, chrpos(1:3,1), chrpos(1:3,natm1+1)
    !#######################################################################################
    !modification if it is not a sphere
if (i .LE. nface1) then
diff=r0-atmpos(1:3,1)
dist=sqrt(dot_product(diff,diff))
diff=diff/dist*atmrad(1)     ! project to the sphere surface
v0=diff/atmrad(1)
r0=atmpos(1:3,1)+diff
else
diff=r0-atmpos(1:3,natm1+1)
dist=sqrt(dot_product(diff,diff))
diff=diff/dist*atmrad(natm1+1)    ! project to the sphere surface
v0=diff/atmrad(natm1+1)
r0=atmpos(1:3,natm1+1)+diff
end if



!for sphere only, need to change if for molecule
    !######################################################################################
    tr_xyz(:,i)=r0			! Get the position of particles
    tr_q(:,i)=v0			! Get the normal of the paricles, acting as charge in treecode
    
    aa=sqrt(dot_product(r(:,1)-r(:,2),r(:,1)-r(:,2)))
    bb=sqrt(dot_product(r(:,1)-r(:,3),r(:,1)-r(:,3)))
    cc=sqrt(dot_product(r(:,2)-r(:,3),r(:,2)-r(:,3)))
   ! tr_area(i)=triangle_area(aa,bb,cc) !gan: flat area, moved to readin file since area wont charge
   ! tr_area(i)=SphereTriArea(r(:,1),r(:,2),r(:,3)) !gan: curved
    							
    ! setup the right hand side of the system of equations
    do j=1,nchr ! for each atom

        rr=chrpos(1:3,j)
        rs=sqrt(dot_product(rr-r0,rr-r0))
!print *,'rr, rs', rr, rs

        G0=1.d0/(4.d0*pi*rs)
        cos_theta=dot_product(v0,rr-r0)/rs
        G1=cos_theta/rs**2/4.d0/pi
    
        bvct(i)=bvct(i)+atmchr(j)*G0/eps0
        bvct(nface+i)=bvct(nface+i)+atmchr(j)*G1/eps0
    enddo
    
enddo
end subroutine

!---------------------------------------------------------------------------------------------------------------
! This subroutine calculate the potential inside or outside given those on surface
subroutine potential_molecule(r0,ptl,iexa,ptl_err)
use molecule
use comdata
use treecode
implicit double precision(a-h,o-z)
real*8 ptl,r0(3),H1,H2,r(3),v(3),s(3),ptl_nD, ptl_err 
real*8 kappa_rs


common // pi,one_over_4pi

ptl=0.d0; ptl_nD=0.d0

do j=1,nface ! for each triangle
    
    r=tr_xyz(:,j)
    v=tr_q(:,j)

    rs=sqrt(dot_product(r-r0,r-r0))
          
    G0=one_over_4pi/rs
    kappa_rs=kappa*rs
    exp_kappa_rs=exp(-kappa_rs)
    Gk=exp_kappa_rs*G0

    cos_theta=dot_product(v,r-r0)/rs

    tp1=G0/rs
    tp2=(1.d0+kappa_rs)*exp_kappa_rs

    G1=cos_theta*tp1
    G2=tp2*G1

    H1=G1-eps*G2
    H2=G0-Gk

    !Derivative method
    ptl=ptl+tr_area(j)*H1*xvct(j)
    ptl=ptl+tr_area(j)*H2*xvct(nface+j)

    !non-Derivative method
    ptl_nD=ptl_nD+tr_area(j)*G1*xvct(j)
    ptl_nD=ptl_nD+tr_area(j)*G0*xvct(nface+j)

    !difference between the two methods 
    !ptl0=ptl0+tr_area(j)*(-eps*G2)*xvct(j)
    !ptl0=ptl0+tr_area(j)*(-Gk)*xvct(nface+j)
    
enddo
    ptl_err=abs(ptl-ptl_nD)/abs(ptl)
    !print *,ptl,ptl_nD,ptl_err

End

!----------------------------------------------------------------------
! This subroutine computer the source charge and target charge for the treecode
! Total Number of Kernel = 2*(1+3*2+3*3)=32
! Refer to the table in the paper for detail

subroutine pb_kernel(phi)
use treecode
use treecode3d_procedures
implicit double precision(a-h,o-z)
integer ikp,ixyz,jxyz,indx !ixyz: source; jxyz target;
real*8 phi(2*numpars) 

do ikp=1,2
	indx=0
	indx=indx+1
	tchg(:,indx,ikp)=1.d0
	schg(:,indx,ikp)=tr_area*phi(numpars+1:2*numpars)
	do iknl=1,2
		do ixyz=1,3
			indx=indx+1
			tchg(:,indx,ikp)=1.d0*(2-iknl)+tr_q(ixyz,:)*(iknl-1)
			schg(:,indx,ikp)=(tr_q(ixyz,:)*(2-iknl)+1.d0*(iknl-1))*tr_area*phi((iknl-1)*numpars+1:iknl*numpars)
		enddo
	enddo
	
	do ixyz=1,3
		do jxyz=1,3
			indx=indx+1
			tchg(:,indx,ikp)=tr_q(jxyz,:)
			schg(:,indx,ikp)=-tr_q(ixyz,:)*tr_area*phi(1:numpars)
		enddo
	enddo
	
enddo

end


!---------------------------------------------------------------------------------------------------------------
! new routine added for multiple domains 
subroutine potential_molecule_mdomains(r0,ptl,ichg)
use molecule
use comdata
use treecode
use treecode3d_procedures
implicit double precision(a-h,o-z)
real*8 ptl,r0(3),H1,H2,r(3),v(3),s(3)
real*8 kappa_rs
integer nchr_sh,nface_sh

common // pi,one_over_4pi

if (imd==1) then
    nchr_sh=nchr/2
    nface_sh=nface/2
else if (imd==2) then
    nchr_sh=nchr1
    nface_sh=nface1
else
    write(*,*) 'parameter imd must equal to 1 or 2 for multiple domains' 
    stop
endif
ptl=0.d0
do j=1,nface ! for each triangle
    jface=orderarr(j) !the original index of the jth elements

    r=tr_xyz(:,j)
    v=tr_q(:,j)

    rs=sqrt(dot_product(r-r0,r-r0))
          
    G0=one_over_4pi/rs
    kappa_rs=kappa*rs
    exp_kappa_rs=exp(-kappa_rs)
    Gk=exp_kappa_rs*G0

    cos_theta=dot_product(v,r-r0)/rs

    tp1=G0/rs
    tp2=(1.d0+kappa_rs)*exp_kappa_rs

    G1=cos_theta*tp1
    G2=tp2*G1

    !non-Derivative method
    H1=G1
    H2=G0
    !Deriative method
    !H1=G1-eps*G2
    !H2=G0-Gk
    if (ichg .le. nchr_sh) then
        if (jface .le. nface_sh) then !inside
            ptl=ptl+tr_area(j)*H1*xvct(j)
            ptl=ptl+tr_area(j)*H2*xvct(nface+j)
        else !outside
           ! ptl=ptl+tr_area(j)*H1*xvct(j)/eps
            !ptl=ptl+tr_area(j)*H2*xvct(nface+j)/eps
        endif
    else !outside
        if (jface .le. nface_sh) then 
        !    ptl=ptl+tr_area(j)*H1*xvct(j)/eps
         !   ptl=ptl+tr_area(j)*H2*xvct(nface+j)/eps
        else !inside
            ptl=ptl+tr_area(j)*H1*xvct(j)
            ptl=ptl+tr_area(j)*H2*xvct(nface+j)
        endif
    endif 

enddo

End


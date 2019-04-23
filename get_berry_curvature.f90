#include "alias.inc"
subroutine get_berry_curvature(NN_TABLE, PINPT, PINPT_BERRY, PGEOM, PKPTS, ETBA)
   use parameters, only : incar, hopping, poscar, energy, berry, kpoints, pauli_0, hbar, eta
   use berry_phase
   use phase_factor
   use mpi_setup
   use kronecker_prod, only: kproduct
   implicit none
   type(hopping) :: NN_TABLE
   type(incar)   :: PINPT
   type(berry)   :: PINPT_BERRY
   type(poscar)  :: PGEOM
   type(energy)  :: ETBA
   type(kpoints) :: PKPTS
   real*8           time1, time2
   integer*4        mpierr

   if_main write(6,*)''
   if_main write(6,'(A)')'START: BERRYCURVATURE' 
#ifdef MPI
   if_main time1 = MPI_Wtime()
#else
   call cpu_time(time1)
#endif

   if(PINPT%flag_erange) then
     if_main write(6,'(A)')'    !WARN! Current version does not support to calculate Berry curvautre'
     if_main write(6,'(A)')'           with ERANGE tag. Please comment out ERANGE -> #ERANGE and re-run'
     if_main write(6,'(A)')'           Exit program...'
     kill_job
   elseif(PINPT%flag_sparse) then
     if_main write(6,'(A)')'    !WARN! Current version does not support to calculate Berry curvautre'
     if_main write(6,'(A)')'           with EWINDOW tag. Please comment out EWINDOW -> #EWINDOW and re-run'
     if_main write(6,'(A)')'           Exit program...'
     kill_job
   endif

   if(PINPT_BERRY%flag_bc_method_kubo) then
     call get_bc_kubo(NN_TABLE, PINPT, PINPT_BERRY, PGEOM, PKPTS, ETBA)

   elseif(PINPT_BERRY%flag_bc_method_resta) then
     call get_bc_resta(NN_TABLE, PINPT, PINPT_BERRY, PGEOM, PKPTS, ETBA)
   endif


#ifdef MPI
   if_main time2 = MPI_Wtime()
#else
   call cpu_time(time2)
#endif
   if_main write(6,'(A,F12.3)')'END: BERRYCURVATURE. TIME ELAPSED (s) =',time2-time1

   return
endsubroutine

!  For the details please find the Ref. [X. Wang et al., PRB 74, 195118 (2006)].
!  "Ab initio calculation of the anomalous Hall conductivity by Wannier interpolation"
!  eqation (9)~(10).
subroutine get_bc_kubo(NN_TABLE, PINPT, PINPT_BERRY, PGEOM, PKPTS, ETBA)
   use parameters, only : incar, hopping, poscar, berry, energy, kpoints, pauli_0, hbar, eta
   use berry_phase
   use phase_factor
   use mpi_setup
   use kronecker_prod, only: kproduct
   use memory
   implicit none
   type(hopping) :: NN_TABLE
   type(incar)   :: PINPT
   type(berry)   :: PINPT_BERRY
   type(energy)  :: ETBA
   type(poscar)  :: PGEOM
   type(kpoints) :: PKPTS
   integer*4        ik, my_ik, is
   integer*4        ieig, feig
   integer*4        nkpoint, neig, ispin, ispinor, msize
   real*8           kpoint(3,PKPTS%nkpoint)
   complex*16       dxH(PGEOM%neig*PINPT%ispinor,PGEOM%neig*PINPT%ispinor)
   complex*16       dyH(PGEOM%neig*PINPT%ispinor,PGEOM%neig*PINPT%ispinor)
   complex*16       dzH(PGEOM%neig*PINPT%ispinor,PGEOM%neig*PINPT%ispinor)
   complex*16, allocatable :: V(:,:,:)
   real*8, parameter, dimension(3):: dkx=(/eta,0d0,0d0/)
   real*8, parameter, dimension(3):: dky=(/0d0,eta,0d0/)
   real*8, parameter, dimension(3):: dkz=(/0d0,0d0,eta/)
   real*8           k1(3), k2(3)
   real*8           omega(PGEOM%neig*PINPT%ispinor,3,PINPT%nspin,PKPTS%nkpoint)
   logical          flag_phase
#ifdef MPI
   integer*4        mpierr
   real*8           omega_(PGEOM%neig*PINPT%ispinor,3,PINPT%nspin,PKPTS%nkpoint)
   integer*4        ourjob(nprocs)
   integer*4        ourjob_disp(0:nprocs-1)
   call mpi_job_distribution_chain(PKPTS%nkpoint, ourjob, ourjob_disp)
   call report_job_distribution(.true., ourjob)
#else
   integer*4        ourjob(1)
   integer*4        ourjob_disp(0)
   call mpi_job_distribution_chain(nkp, ourjob, ourjob_disp)
   call report_job_distribution(.true., ourjob)
#endif

   allocate(PINPT_BERRY%omega(PGEOM%neig*PINPT%ispinor,3,PINPT%nspin,PKPTS%nkpoint))
   PINPT_BERRY%omega = 0d0

   kpoint = PKPTS%kpoint   ; nkpoint = PKPTS%nkpoint
   neig   = PGEOM%neig     ; ispinor = PINPT%ispinor ; ispin = PINPT%ispin
   msize  = neig * ispinor ; omega   = 0d0
   flag_phase = PINPT_BERRY%flag_bc_phase
   if_main call report_memory((int8(neig)*int8(ispin))**2 * int8(nkpoint)*2, 16, 'Eigen vectors') ! V + ETBA%V

#ifdef MPI
   if(.not. allocated(V)) allocate(V(neig*ispin,neig*ispin,ourjob(myid+1)))
   call MPI_SCATTERV(ETBA%V, ourjob*neig*ispinor*neig*ispinor, &
                             ourjob_disp*neig*ispinor*neig*ispinor, &
                             MPI_COMPLEX16, V, &
                             ourjob(myid+1)*neig*ispinor*neig*ispinor, &
                             MPI_COMPLEX16, 0, mpi_comm_earth, mpierr)
#else
   if(.not. allocated(V)) allocate(V(neig*ispin,neig*ispin,nkpoint))
   V = ETBA%V
#endif

sp:do is = 1, PINPT%nspin
     ieig = 1 + (is-1)*neig ; feig = neig*ispinor + (is-1)*neig
  kp:do ik= sum(ourjob(1:myid))+1, sum(ourjob(1:myid+1))
       my_ik = ik - sum(ourjob(1:myid))
       
       call get_velocity_matrix(PINPT, NN_TABLE, kpoint(:,ik), neig, dzH, dzF_IJ, flag_phase)
       call get_velocity_matrix(PINPT, NN_TABLE, kpoint(:,ik), neig, dxH, dxF_IJ, flag_phase)
       call get_velocity_matrix(PINPT, NN_TABLE, kpoint(:,ik), neig, dyH, dyF_IJ, flag_phase)
       call get_omega(omega(:,:,is,ik), ETBA%E(ieig:feig,ik), V(ieig:feig,ieig:feig,my_ik), dxH, dyH, dzH, msize)
       if(PINPT%flag_collinear) then
         if_main write(6,'(A,F10.3,A)')'  STATUS: ',real(my_ik)/real(ourjob(myid+1))*100d0,' %'
       elseif(.not. PINPT%flag_collinear) then
         if_main write(6,'(A,F10.3,A,I0)')'  STATUS: ',real(my_ik)/real(ourjob(myid+1))*100d0,' % ; SPIN: ',is
       endif
     enddo kp
   enddo sp


#ifdef MPI
   call MPI_Reduce(omega, omega_, size(omega), MPI_REAL8, MPI_SUM, 0, mpi_comm_earth, mpierr)
   if_main omega = omega_
   PINPT_BERRY%omega = omega
   if_main call print_berrycurvature(PINPT, PINPT_BERRY, PKPTS, PGEOM, ETBA%E, 'total')
   if_main call print_berrycurvature(PINPT, PINPT_BERRY, PKPTS, PGEOM, ETBA%E, 'range')
#else
   PINPT_BERRY%omega = omega
   call print_berrycurvature(PINPT, PINPT_BERRY, PKPTS, PGEOM, ETBA%E, 'total')
   call print_berrycurvature(PINPT, PINPT_BERRY, PKPTS, PGEOM, ETBA%E, 'range')
#endif

   deallocate(V)
   return
endsubroutine

subroutine get_bc_resta(NN_TABLE, PINPT, PINPT_BERRY, PGEOM, PKPTS, ETBA)
   use parameters, only : incar, hopping, poscar, berry, energy, kpoints, pauli_0, hbar, eta
   use berry_phase
   use phase_factor
   use mpi_setup
   use kronecker_prod, only: kproduct
   implicit none
   type(hopping) :: NN_TABLE
   type(incar)   :: PINPT
   type(berry)   :: PINPT_BERRY
   type(energy)  :: ETBA
   type(poscar)  :: PGEOM
   type(kpoints) :: PKPTS
   integer*4        neig, ispinor, msize
   integer*4        mpierr
   character*4      loop_mode ! 'rect' or 'line'
   character*2      loop_axis ! 'kx', 'ky', 'kz', k0 -> 1D linemode
   real*4           kp_init(3)

   neig   = PGEOM%neig     ; ispinor = PINPT%ispinor
   msize  = neig * ispinor 

   write(6,*)"XXXX", PINPT_BERRY%bc_nkdiv
!  call set_kpath_plane(PINPT_BERRY%bc_kpoint(:,:,:,ip,ix), PINPT_BERRY%z2_kpoint_reci(:,:,:,ip,ix), kpath, nkdiv, nkpath, z2_axis(ix), shift(ip), PGEOM)

!  if(PKPTS%flag_klinemode) then
!    if_main write(6,*)'  WARN: BERRY CURVATURE EVALUATION WITH ALONG WITH THE METHOD OF "RESTA"'
!    if_main write(6,*)'        CANNOT BE RUN WITH "KLINE_MODE". PLEASE CHECK YOUR "KFILE"'
!  endif

#ifdef MPI
!    mpi_kill
!    stop
#else
!    stop
#endif

!  call set_berry_loop(kp_init, loop_mode, loop_axis)

   write(6,*)"AAAVV "
stop

   return
endsubroutine

module pelec_util_module

  implicit none

contains

  ! Given 3D indices (i,j,k), return the cell-centered spatial position.
  ! Optionally we can also be edge-centered in any of the directions.

  function position(i, j, k, ccx, ccy, ccz)

    use amrinfo_module, only: amr_level
    use prob_params_module, only: problo, probhi, physbc_lo, physbc_hi, dx_level, &
                                  domlo_level, domhi_level, Interior
    use amrex_constants_module, only: ZERO, HALF

    ! Input arguments
    integer :: i, j, k
    logical, optional :: ccx, ccy, ccz

    ! Local variables
    double precision :: position(3), dx(3), offset(3)
    integer :: idx(3)
    logical :: cc(3)
    integer :: domlo(3), domhi(3)
    integer :: dir

    idx = (/ i, j, k /)

    dx(:) = dx_level(:,amr_level)
    domlo = domlo_level(:,amr_level)
    domhi = domhi_level(:,amr_level)

    offset(:) = problo(:)

    cc(:) = .true.

    if (present(ccx)) then
       cc(1) = ccx
    endif

    if (present(ccy)) then
       cc(2) = ccy
    endif

    if (present(ccz)) then
       cc(3) = ccz
    endif

    do dir = 1, 3
       if (cc(dir)) then
          ! If we're cell-centered, we want to be in the middle of the zone.

          offset(dir) = offset(dir) + HALF * dx(dir)
       else
          ! Take care of the fact that for edge-centered indexing,
          ! we actually range from (domlo, domhi+1).

          domhi(dir) = domhi(dir) + 1
       endif
    enddo

    ! Be careful when using periodic boundary conditions. In that case,
    ! we need to loop around to the other side of the domain.

    do dir = 1, 3
       if      (physbc_lo(dir) .eq. Interior .and. idx(dir) .lt. domlo(dir)) then
          offset(dir) = offset(dir) + (probhi(dir) - problo(dir))
       else if (physbc_hi(dir) .eq. Interior .and. idx(dir) .gt. domhi(dir)) then
          offset(dir) = offset(dir) + (problo(dir) - probhi(dir))
       endif
    enddo

    position(:) = offset(:) + dble(idx(:)) * dx(:)

  end function position



  subroutine pc_enforce_consistent_e(lo,hi,state,s_lo,s_hi) &
       bind(C, name="pc_enforce_consistent_e")

    use meth_params_module, only : NVAR, URHO, UMX, UMY, UMZ, UEDEN, UEINT
    use amrex_constants_module

    implicit none

    integer          :: lo(3), hi(3)
    integer          :: s_lo(3), s_hi(3)
    double precision :: state(s_lo(1):s_hi(1),s_lo(2):s_hi(2),s_lo(3):s_hi(3),NVAR)

    ! Local variables
    integer          :: i,j,k
    double precision :: u, v, w, rhoInv

    !
    ! Enforces (rho E) = (rho e) + 1/2 rho (u^2 + v^2 + w^2)
    !
    do k = lo(3), hi(3)
       do j = lo(2), hi(2)
          do i = lo(1), hi(1)

             rhoInv = ONE / state(i,j,k,URHO)
             u = state(i,j,k,UMX) * rhoInv
             v = state(i,j,k,UMY) * rhoInv
             w = state(i,j,k,UMZ) * rhoInv

             state(i,j,k,UEDEN) = state(i,j,k,UEINT) + &
                  HALF * state(i,j,k,URHO) * (u*u + v*v + w*w)

          end do
       end do
    end do

  end subroutine pc_enforce_consistent_e



  subroutine reset_internal_e(lo,hi,u,u_lo,u_hi,verbose) &
       bind(C, name="reset_internal_e")

    use eos_module
    use eos_type_module
    use network, only : nspec, naux
    use meth_params_module, only : NVAR, URHO, UMX, UMY, UMZ, UEDEN, UEINT, UFS, UFX, &
         UTEMP, small_temp, allow_negative_energy, allow_small_energy, &
         dual_energy_eta2, dual_energy_update_E_from_e
    use amrex_constants_module

    implicit none

    integer          :: lo(3), hi(3), verbose
    integer          :: u_lo(3), u_hi(3)
    double precision :: u(u_lo(1):u_hi(1),u_lo(2):u_hi(2),u_lo(3):u_hi(3),NVAR)

    ! Local variables
    integer          :: i,j,k
    double precision :: Up, Vp, Wp, ke, rho_eint, eden, small_e, eint_new, rhoInv

    type (eos_t) :: eos_state

    call build(eos_state)

    ! Reset internal energy

    ! First, check if the internal energy variable is
    ! smaller than the internal energy computed via
    ! a call to the EOS using the small temperature.
    ! If so, reset it using the current temperature,
    ! assuming it is at least as large as small_temp.
    ! Note that allow_small_energy .eq. 0 overrides
    ! allow_negative_energy .eq. 0 since a negative
    ! energy is of course smaller than the smallest
    ! allowed energy.

    if (allow_small_energy .eq. 0) then

       do k = lo(3), hi(3)
          do j = lo(2), hi(2)
             do i = lo(1), hi(1)

                rhoInv = ONE / u(i,j,k,URHO)
                Up = u(i,j,k,UMX) * rhoInv
                Vp = u(i,j,k,UMY) * rhoInv
                Wp = u(i,j,k,UMZ) * rhoInv
                ke = HALF * (Up**2 + Vp**2 + Wp**2)
                eden = u(i,j,k,UEDEN) * rhoInv

                eos_state % rho      = u(i,j,k,URHO)
                eos_state % T        = small_temp
                eos_state % massfrac = u(i,j,k,UFS:UFS+nspec-1) * rhoInv
                eos_state % aux      = u(i,j,k,UFX:UFX+naux-1) * rhoInv

                call eos_rt(eos_state)

                small_e = eos_state % e

                ! If E < small_e, reset it so that it's equal to internal + kinetic.

                if (eden < small_e) then

                   if (u(i,j,k,UEINT) * rhoInv < small_e) then

                      eos_state % T = max(u(i,j,k,UTEMP), small_temp)

                      call eos_rt(eos_state)

                      u(i,j,k,UEINT) = u(i,j,k,URHO) * eos_state % e

                   endif

                   u(i,j,k,UEDEN) = u(i,j,k,UEINT) + u(i,j,k,URHO) * ke

                else

                   rho_eint = u(i,j,k,UEDEN) - u(i,j,k,URHO) * ke

                   ! Reset (e from e) if it's greater than eta * E.

                   if (rho_eint .gt. u(i,j,k,URHO)*mine .and. &
                        (rho_eint-u(i,j,k,URHO)*mine) / (u(i,j,k,UEDEN)-u(i,j,k,URHO)*mine) .gt. dual_energy_eta2) then

                      u(i,j,k,UEINT) = rho_eint

                   endif

                   if (u(i,j,k,UEINT) * rhoInv < small_e) then

                      eos_state % T = max(u(i,j,k,UTEMP), small_temp)

                      call eos_rt(eos_state)

                      if (dual_energy_update_E_from_e == 1) then
                         u(i,j,k,UEDEN) = u(i,j,k,UEDEN) + (u(i,j,k,URHO) * eos_state % e - u(i,j,k,UEINT))
                      endif

                      u(i,j,k,UEINT) = u(i,j,k,URHO) * eos_state % e

                   endif

                endif

             enddo
          enddo
       enddo

    else if (allow_negative_energy .eq. 0) then

       do k = lo(3), hi(3)
          do j = lo(2), hi(2)
             do i = lo(1), hi(1)

                rhoInv = ONE/u(i,j,k,URHO)
                Up = u(i,j,k,UMX) * rhoInv
                Vp = u(i,j,k,UMY) * rhoInv
                Wp = u(i,j,k,UMZ) * rhoInv
                ke = HALF * (Up**2 + Vp**2 + Wp**2)

                if (u(i,j,k,UEDEN) < u(i,j,k,URHO)*mine) then

                   if (u(i,j,k,UEINT) < u(i,j,k,URHO)*mine) then

                      eos_state % rho         = u(i,j,k,URHO)
                      eos_state % T           = small_temp
                      eos_state % massfrac(:) = u(i,j,k,UFS:UFS+nspec-1) * rhoInv
                      eos_state % aux(1:naux) = u(i,j,k,UFX:UFX+naux-1) * rhoInv

                      call eos_rt(eos_state)

                      u(i,j,k,UEINT) = u(i,j,k,URHO) * eos_state % e

                   endif

                   u(i,j,k,UEDEN) = u(i,j,k,UEINT) + u(i,j,k,URHO) * ke

                else

                   rho_eint = u(i,j,k,UEDEN) - u(i,j,k,URHO) * ke

                   ! Reset (e from e) if it's greater than eta * E.
                   if (rho_eint .gt. u(i,j,k,URHO)*mine .and. &
                        (rho_eint-u(i,j,k,URHO)*mine) / (u(i,j,k,UEDEN)-u(i,j,k,URHO)*mine) .gt. dual_energy_eta2) then

                      u(i,j,k,UEINT) = rho_eint

                      ! If (e from E) < 0 or (e from E) < .0001*E but (e from e) > 0.
                   else if (u(i,j,k,UEINT) .gt. u(i,j,k,URHO)*mine .and. dual_energy_update_E_from_e == 1) then

                      u(i,j,k,UEDEN) = u(i,j,k,UEINT) + u(i,j,k,URHO) * ke

                      ! If not resetting and little e is negative ...
                   else if (u(i,j,k,UEINT) .le. u(i,j,k,URHO)*mine) then

                      eos_state % rho         = u(i,j,k,URHO)
                      eos_state % T           = small_temp
                      eos_state % massfrac(:) = u(i,j,k,UFS:UFS+nspec-1) * rhoInv
                      eos_state % aux(1:naux) = u(i,j,k,UFX:UFX+naux-1) * rhoInv

                      call eos_rt(eos_state)

                      eint_new = eos_state % e

                      if (verbose .gt. 0) then
                         print *,'   '
                         print *,'>>> Warning: PeleC_util.F90::reset_internal_energy  ',i,j,k
                         print *,'>>> ... resetting neg. e from EOS using small_temp'
                         print *,'>>> ... from ',u(i,j,k,UEINT)/u(i,j,k,URHO),' to ', eint_new
                         print *,'    '
                      end if

                      if (dual_energy_update_E_from_e == 1) then
                         u(i,j,k,UEDEN) = u(i,j,k,UEDEN) + (u(i,j,k,URHO) * eint_new - u(i,j,k,UEINT))
                      endif

                      u(i,j,k,UEINT) = u(i,j,k,URHO) * eint_new

                   endif
                end if
             enddo
          enddo
       enddo

       ! If (allow_negative_energy .eq. 1) and (allow_small_energy .eq. 1)
       ! then just reset (rho e) from (rho E)
    else

       do k = lo(3), hi(3)
          do j = lo(2), hi(2)
             do i = lo(1), hi(1)

                rhoInv = ONE/u(i,j,k,URHO)
                Up = u(i,j,k,UMX) * rhoInv
                Vp = u(i,j,k,UMY) * rhoInv
                Wp = u(i,j,k,UMZ) * rhoInv
                ke = HALF * (Up**2 + Vp**2 + Wp**2)

                u(i,j,k,UEINT) = u(i,j,k,UEDEN) - u(i,j,k,URHO) * ke

             enddo
          enddo
       enddo

    endif

    call destroy(eos_state)

  end subroutine reset_internal_e  



  subroutine compute_temp(lo,hi,state,s_lo,s_hi) &
       bind(C, name="compute_temp")

    use network, only : nspec, naux
    use eos_type_module
    use eos_module
    use meth_params_module, only : NVAR, URHO, UEDEN, UEINT, UTEMP, &
         UFS, UFX, allow_negative_energy, dual_energy_update_E_from_e
    use amrex_constants_module

    implicit none

    integer         , intent(in   ) :: lo(3),hi(3)
    integer         , intent(in   ) :: s_lo(3),s_hi(3)
    double precision, intent(inout) :: state(s_lo(1):s_hi(1),s_lo(2):s_hi(2),s_lo(3):s_hi(3),NVAR)

    integer          :: i,j,k
    double precision :: rhoInv

    type (eos_t) :: eos_state

    call build(eos_state)

    ! First check the inputs for validity.

    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)

             if (state(i,j,k,URHO) <= mindens) then
                print *,'   '
                print *,'>>> Error: PeleC_util.F90::compute_temp ',i,j,k
                print *,'>>> ... density out of bounds',state(i,j,k,URHO)
                print *,'    '
                call bl_error("Error:: compute_temp_nd.f90")
             end if

             if (allow_negative_energy .eq. 0 .and. state(i,j,k,UEINT) <= state(i,j,k,URHO)*mine) then
                print *,'   '
                print *,'>>> Warning: PeleC_util.F90::compute_temp ',i,j,k
                print *,'>>> ... (rho e) out of bounds',state(i,j,k,UEINT)
                print *,'   '
                call bl_error("Error:: compute_temp_nd.f90")
             end if

          enddo
       enddo
    enddo

    do k = lo(3), hi(3)
       do j = lo(2), hi(2)
          do i = lo(1), hi(1)

             rhoInv = ONE / state(i,j,k,URHO)

             eos_state % rho      = state(i,j,k,URHO)
             eos_state % T        = state(i,j,k,UTEMP) ! Initial guess for the EOS
             eos_state % e        = state(i,j,k,UEINT) * rhoInv
             eos_state % massfrac = state(i,j,k,UFS:UFS+nspec-1) * rhoInv
             eos_state % aux      = state(i,j,k,UFX:UFX+naux-1) * rhoInv

             call eos_re(eos_state)

             state(i,j,k,UTEMP) = eos_state % T
          enddo
       enddo
    enddo

    call destroy(eos_state)

  end subroutine compute_temp 



  subroutine pc_check_initial_species(lo,hi,state,state_lo,state_hi) &
                                      bind(C, name="pc_check_initial_species")

    use network           , only : nspec
    use meth_params_module, only : NVAR, URHO, UFS
    use amrex_constants_module

    implicit none

    integer          :: lo(3), hi(3)
    integer          :: state_lo(3), state_hi(3)
    double precision :: state(state_lo(1):state_hi(1),state_lo(2):state_hi(2),state_lo(3):state_hi(3),NVAR)

    ! Local variables
    integer          :: i, j, k
    double precision :: spec_sum

    do k = lo(3), hi(3)
       do j = lo(2), hi(2)
          do i = lo(1), hi(1)

             spec_sum = sum(state(i,j,k,UFS:UFS+nspec-1))

             if (abs(state(i,j,k,URHO)-spec_sum) .gt. 1.d-8 * state(i,j,k,URHO)) then

                print *,'Sum of (rho X)_i vs rho at (i,j,k): ',i,j,k,spec_sum,state(i,j,k,URHO)
                call bl_error("Error:: Failed check of initial species summing to 1")

             end if

          enddo
       enddo
    enddo

  end subroutine pc_check_initial_species



  ! Given 3D spatial coordinates, return the cell-centered zone indices closest to it.
  ! Optionally we can also be edge-centered in any of the directions.
  
  function position_to_index(loc) result(index)

    use amrinfo_module, only: amr_level
    use prob_params_module, only: dx_level, dim
    
    double precision :: loc(3)

    integer :: index(3)

    index(1:dim)   = NINT(loc(1:dim) / dx_level(1:dim,amr_level))
    index(dim+1:3) = 0
    
  end function position_to_index  



  ! Given 3D indices (i,j,k) and a direction dir, return the
  ! area of the face perpendicular to direction d. We assume
  ! the coordinates perpendicular to the dir axies are edge-centered.
  ! Note that PeleC has no support for angular coordinates, so 
  ! this function only provides Cartesian in 1D/2D/3D, Cylindrical (R-Z)
  ! in 2D, and Spherical in 1D.

  function area(i, j, k, dir)

    use amrinfo_module, only: amr_level
    use amrex_constants_module, only: ZERO, ONE, TWO, M_PI, FOUR
    use prob_params_module, only: dim, coord_type, dx_level

    implicit none

    integer, intent(in) :: i, j, k, dir

    double precision :: area

    logical :: cc(3) = .true.
    double precision :: dx(3), loc(3)

    ! Force edge-centering along the direction of interest

    cc(dir) = .false.

    dx = dx_level(:,amr_level)

    if (coord_type .eq. 0) then

       ! Cartesian (1D/2D/3D)

       if (dim .eq. 1) then

          select case (dir)

          case (1)
             area = ONE
          case default
             area = ZERO

          end select

       else if (dim .eq. 2) then

          select case (dir)

          case (1)
             area = dx(2)
          case (2)
             area = dx(1)
          case default
             area = ZERO

          end select

       else if (dim .eq. 3) then

          select case (dir)

          case (1)
             area = dx(2) * dx(3)
          case (2)
             area = dx(1) * dx(3)
          case (3)
             area = dx(1) * dx(2)
          case default
             area = ZERO

          end select

       endif

    else if (coord_type .eq. 1) then

       ! Cylindrical (2D only)

       ! Get edge-centered position

       loc = position(i,j,k,cc(1),cc(2),cc(3))

       if (dim .eq. 2) then

          select case (dir)

          case (1)
             area = TWO * M_PI * loc(1) * dx(2)
          case (2)
             area = TWO * M_PI * loc(1) * dx(1)
          case default
             area = ZERO

          end select

       else

          call bl_error("Cylindrical coordinates only supported in 2D.")

       endif

    else if (coord_type .eq. 2) then

       ! Spherical (1D only)

       ! Get edge-centered position

       loc = position(i,j,k,cc(1),cc(2),cc(3))

       if (dim .eq. 1) then

          select case (dir)

          case (1)
             area = FOUR * M_PI * loc(1)**2
          case default
             area = ZERO

          end select

       else

          call bl_error("Spherical coordinates only supported in 1D.")

       endif

    endif

  end function area



  ! Given 3D cell-centered indices (i,j,k), return the volume of the zone.
  ! Note that PeleC has no support for angular coordinates, so 
  ! this function only provides Cartesian in 1D/2D/3D, Cylindrical (R-Z)
  ! in 2D, and Spherical in 1D.

  function volume(i, j, k)

    use amrinfo_module, only: amr_level
    use amrex_constants_module, only: ZERO, HALF, FOUR3RD, TWO, M_PI
    use prob_params_module, only: dim, coord_type, dx_level

    implicit none

    integer, intent(in) :: i, j, k

    double precision :: volume

    double precision :: dx(3), loc_l(3), loc_r(3)

    dx = dx_level(:,amr_level)

    if (coord_type .eq. 0) then

       ! Cartesian (1D/2D/3D)

       if (dim .eq. 1) then

          volume = dx(1)

       else if (dim .eq. 2) then

          volume = dx(1) * dx(2)

       else if (dim .eq. 3) then

          volume = dx(1) * dx(2) * dx(3)

       endif

    else if (coord_type .eq. 1) then

       ! Cylindrical (2D only)

       ! Get inner and outer radii

       loc_l = position(i  ,j,k,ccx=.true.)
       loc_r = position(i+1,j,k,ccx=.true.)

       if (dim .eq. 2) then

          volume = TWO * M_PI * (HALF * (loc_l(1) + loc_r(1))) * dx(1) * dx(2)

       else

          call bl_error("Cylindrical coordinates only supported in 2D.")

       endif

    else if (coord_type .eq. 2) then

       ! Spherical (1D only)

       ! Get inner and outer radii

       loc_l = position(i  ,j,k,ccx=.true.)
       loc_r = position(i+1,j,k,ccx=.true.)

       if (dim .eq. 1) then

          volume = FOUR3RD * M_PI * (loc_r(1)**3 - loc_l(1)**3)

       else

          call bl_error("Spherical coordinates only supported in 1D.")

       endif

    endif

  end function volume



  subroutine pc_compute_avgstate(lo,hi,dx,dr,nc,&
                                 state,s_lo,s_hi,radial_state, &
                                 vol,v_lo,v_hi,radial_vol, &
                                 problo,numpts_1d) &
                                 bind(C, name="pc_compute_avgstate")

    use meth_params_module, only : URHO, UMX, UMY, UMZ
    use prob_params_module, only : center, dim
    use amrex_constants_module

    implicit none

    integer          :: lo(3),hi(3),nc
    double precision :: dx(3),dr,problo(3)

    integer          :: numpts_1d
    double precision :: radial_state(nc,0:numpts_1d-1)
    double precision :: radial_vol(0:numpts_1d-1)

    integer          :: s_lo(3), s_hi(3)
    double precision :: state(s_lo(1):s_hi(1),s_lo(2):s_hi(2),s_lo(3):s_hi(3),nc)

    integer          :: v_lo(3), v_hi(3)
    double precision :: vol(v_lo(1):v_hi(1),v_lo(2):v_hi(2),v_lo(3):v_hi(3))

    integer          :: i,j,k,n,index
    double precision :: x,y,z,r
    double precision :: x_mom,y_mom,z_mom,radial_mom

    if (dim .eq. 1) call bl_error("Error: cannot do pc_compute_avgstate in 1D.")

    !
    ! Do not OMP this.
    !
    do k = lo(3), hi(3)
       z = problo(3) + (dble(k)+HALF) * dx(3) - center(3)
       do j = lo(2), hi(2)
          y = problo(2) + (dble(j)+HALF) * dx(2) - center(2)
          do i = lo(1), hi(1)
             x = problo(1) + (dble(i)+HALF) * dx(1) - center(1)
             r = sqrt(x**2 + y**2 + z**2)
             index = int(r/dr)
             if (index .gt. numpts_1d-1) then
                print *,'COMPUTE_AVGSTATE: INDEX TOO BIG ',index,' > ',numpts_1d-1
                print *,'AT (i,j,k) ',i,j,k
                print *,'R / DR ',r,dr
                call bl_error("Error:: PeleC_util.F90 :: pc_compute_avgstate")
             end if
             radial_state(URHO,index) = radial_state(URHO,index) &
                                      + vol(i,j,k)*state(i,j,k,URHO)
             !
             ! Store the radial component of the momentum in the 
             ! UMX, UMY and UMZ components for now.
             !
             x_mom = state(i,j,k,UMX)
             y_mom = state(i,j,k,UMY)
             z_mom = state(i,j,k,UMZ)
             radial_mom = x_mom * (x/r) + y_mom * (y/r) + z_mom * (z/r)
             radial_state(UMX,index) = radial_state(UMX,index) + vol(i,j,k)*radial_mom
             radial_state(UMY,index) = radial_state(UMY,index) + vol(i,j,k)*radial_mom
             radial_state(UMZ,index) = radial_state(UMZ,index) + vol(i,j,k)*radial_mom

             do n = UMZ+1,nc
                radial_state(n,index) = radial_state(n,index) + vol(i,j,k)*state(i,j,k,n)
             end do
             radial_vol(index) = radial_vol(index) + vol(i,j,k)
          enddo
       enddo
    enddo

  end subroutine pc_compute_avgstate



  function linear_to_angular_momentum(loc, mom) result(ang_mom)

    implicit none

    double precision :: loc(3), mom(3)
    double precision :: ang_mom(3)

    ang_mom(1) = loc(2) * mom(3) - loc(3) * mom(2)
    ang_mom(2) = loc(3) * mom(1) - loc(1) * mom(3)
    ang_mom(3) = loc(1) * mom(2) - loc(2) * mom(1)

  end function linear_to_angular_momentum

end module pelec_util_module

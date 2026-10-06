package com.arturo.account.repository;

import org.springframework.data.jpa.repository.JpaRepository;

import com.arturo.account.model.Role;

public interface RoleRepository extends JpaRepository<Role, Long>{
}

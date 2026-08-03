"""
Central identity + multi-app RBAC schema — SQLAlchemy 2.0 ORM models.

Target: PostgreSQL (uses UUID, JSONB, CITEXT). Requires:
    pip install sqlalchemy psycopg2-binary sqlalchemy-citext

Mirrors auth_schema.sql 1:1 -- same tables, same relationships, same
separation between:
  - identity        (User)
  - app registry     (App)
  - access gate       (UserAppAccess)  -- can this user use this app at all?
  - RBAC              (Role, Permission, RolePermission, UserRole)
  - sessions          (Session)
  - audit             (AuthAuditLog)
"""

import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    ForeignKey,
    String,
    Text,
    Boolean,
    Integer,
    DateTime,
    UniqueConstraint,
    Index,
    func,
    Uuid,
    JSON
)
from sqlalchemy.orm import (
    DeclarativeBase,
    Mapped,
    mapped_column,
    relationship,
)


class Base(DeclarativeBase):
    pass


# ============================================================================
# Enums
# ============================================================================

class UserStatus(str, enum.Enum):
    pending_verification = "pending_verification"
    active = "active"
    disabled = "disabled"
    locked = "locked"


class UserTokenPurpose(str, enum.Enum):
    email_verify = "email_verify"
    password_reset = "password_reset"


class AppAccessStatus(str, enum.Enum):
    active = "active"
    revoked = "revoked"
    pending_approval = "pending_approval"

# ============================================================================
# 1. USERS  (the central account -- lives ONLY here, not per-app)
# ============================================================================

class User(Base):
    __tablename__ = "users"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, primary_key=True, default=uuid.uuid4
    )
    email: Mapped[str] = mapped_column(Text, unique=True, nullable=False)
    username: Mapped[str] = mapped_column(Text, unique=True, nullable=False)

    # NEVER store plaintext or reversibly-encrypted passwords.
    # password_hash should be a full argon2id/bcrypt string, e.g. "$argon2id$v=19$..."
    # produced by something like passlib.hash.argon2 -- algorithm, salt, and cost
    # factor all live inside the hash string itself.
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    password_updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    status: Mapped[UserStatus] = mapped_column(
        default=UserStatus.pending_verification, nullable=False
    )
    email_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # basic brute-force protection
    failed_login_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # relationships
    tokens: Mapped[list["UserToken"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    user_app_access: Mapped[list["UserAppAccess"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    roles: Mapped[list["UserRole"]] = relationship(
        back_populates="user", foreign_keys="UserRole.user_id", cascade="all, delete-orphan"
    )
    groups: Mapped[list["GroupUser"]] = relationship(
        back_populates="user", foreign_keys="GroupUser.user_id", cascade="all, delete-orphan"
    )
    sessions: Mapped[list["Session"]] = relationship(back_populates="user", cascade="all, delete-orphan")

    __table_args__ = (Index("idx_users_status", "status"),)

## CURRENTLY NOT USED ##
class UserToken(Base):
    """Short-lived tokens for email verification / password reset.
    Store the token HASHED (e.g. sha256), never raw -- the raw value only
    ever exists in the email/SMS you send out.
    """
    __tablename__ = "user_tokens"

    token_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False
    )
    purpose: Mapped[UserTokenPurpose] = mapped_column(nullable=False)
    token_hash: Mapped[str] = mapped_column(Text, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    user: Mapped["User"] = relationship(back_populates="tokens")

    __table_args__ = (Index("idx_user_tokens_lookup", "user_id", "purpose"),)

# TO DO FINISH 
class Group(Base): 
    __tablename__ = "groups"

    group_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    group_key: Mapped[str] = mapped_column(Text, unique=True, nullable=False)  # e.g. "group-xyz"
    name: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    
    #Relationships
    group_user: Mapped[list["GroupUser"]] = relationship(back_populates="group", cascade="all, delete-orphan")
    group_app_access: Mapped[list["GroupAppAccess"]] = relationship(back_populates="group", cascade="all, delete-orphan")
    group_roles: Mapped[list["GroupRole"]] = relationship(back_populates="group", cascade="all, delete-orphan")
# ============================================================================
# 2. APPS  (registry -- any new app just gets a row here, no schema change)
# ============================================================================

class App(Base):
    __tablename__ = "apps"

    app_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    app_key: Mapped[str] = mapped_column(Text, unique=True, nullable=False)  # e.g. "invoicing-app"
    name: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str | None] = mapped_column(Text)

    owner_contact: Mapped[str | None] = mapped_column(Text)

    # Landing Zone tile fields (accessConsole's Home page): where to send
    # a user who clicks this app, its icon, and a hover-only blurb
    # distinct from `description` (which is the tile's always-visible text).
    url: Mapped[str | None] = mapped_column(Text)
    icon_url: Mapped[str | None] = mapped_column(Text)
    tooltip_text: Mapped[str | None] = mapped_column(Text)

    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    user_access_grants: Mapped[list["UserAppAccess"]] = relationship(back_populates="app", cascade="all, delete-orphan")
    group_access_grants: Mapped[list["GroupAppAccess"]] = relationship(back_populates="app", cascade="all, delete-orphan")
    roles: Mapped[list["Role"]] = relationship(back_populates="app", cascade="all, delete-orphan")
    permissions: Mapped[list["Permission"]] = relationship(back_populates="app", cascade="all, delete-orphan")


# ============================================================================
# 3. APP ACCESS GATE  (can this user use this app at all?)
# ============================================================================
# Deliberately separate from roles/permissions below -- answers a coarse
# yes/no fast, and lets you revoke access to one app without touching a
# user's role assignments elsewhere.

class UserAppAccess(Base):
    __tablename__ = "user_app_access"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.user_id", ondelete="CASCADE"), primary_key=True
    )
    app_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("apps.app_id", ondelete="CASCADE"), primary_key=True
    )
    status: Mapped[AppAccessStatus] = mapped_column(default=AppAccessStatus.active, nullable=False)
    granted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    user: Mapped["User"] = relationship(back_populates="user_app_access")
    app: Mapped["App"] = relationship(back_populates="user_access_grants")

    __table_args__ = (Index("idx_user_app_access_app", "app_id", "status"),)
    
    
class GroupAppAccess(Base):
    __tablename__ = "group_app_access"

    group_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("groups.group_id", ondelete="CASCADE"), primary_key=True
    )
    app_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("apps.app_id", ondelete="CASCADE"), primary_key=True
    )
    status: Mapped[AppAccessStatus] = mapped_column(default=AppAccessStatus.active, nullable=False)
    granted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    group: Mapped["Group"] = relationship(back_populates="group_app_access")
    app: Mapped["App"] = relationship(back_populates="group_access_grants")

    __table_args__ = (Index("idx_group_app_access_app", "app_id", "status"),)

    
# ============================================================================
# 5. TODO USER TO GOUPS 
# ============================================================================
#
#
#

class GroupUser(Base):
    __tablename__ = "group_user"

    group_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("groups.group_id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.user_id", ondelete="CASCADE"), primary_key=True
    )

    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    added_by: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.user_id")
    )  # who assigned this role (audit trail)

    group: Mapped["Group"] = relationship(back_populates="group_user")
    user: Mapped["User"] = relationship(back_populates="groups", foreign_keys=[user_id])
    adder: Mapped["User | None"] = relationship(foreign_keys=[added_by])

    __table_args__ = (Index("idx_group_user_user", "user_id"),)
    
# ============================================================================
# 5. RBAC  (what can they do inside an app they have access to?)
# ============================================================================
# roles/permissions are scoped to an app via app_id. app_id may be NULL for
# a small number of GLOBAL roles (e.g. "super_admin" spanning all apps) --
# use sparingly, that's where privilege creep sneaks in.

class Role(Base):
    __tablename__ = "roles"

    role_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    app_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("apps.app_id", ondelete="CASCADE"), nullable = False
    )  
    role_name: Mapped[str] = mapped_column(Text, nullable=False)  # "admin, "editor", "viewer"
    description: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    app: Mapped["App | None"] = relationship(back_populates="roles")
    role_permissions: Mapped[list["RolePermission"]] = relationship(back_populates="role", cascade="all, delete-orphan")
    user_roles: Mapped[list["UserRole"]] = relationship(back_populates="role", cascade="all, delete-orphan")
    group_roles: Mapped[list["GroupRole"]] = relationship(back_populates="role", cascade="all, delete-orphan")

    __table_args__ = (UniqueConstraint("app_id", "role_name", name="uq_role_app_name"),)


class Permission(Base):
    __tablename__ = "permissions"

    permission_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    app_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("apps.app_id", ondelete="CASCADE"), nullable = False
    )  
    permission_name: Mapped[str] = mapped_column(Text, nullable=False)  # "invoice.create"
    description: Mapped[str | None] = mapped_column(Text)

    app: Mapped["App | None"] = relationship(back_populates="permissions")
    role_permissions: Mapped[list["RolePermission"]] = relationship(back_populates="permission", cascade="all, delete-orphan")

    __table_args__ = (UniqueConstraint("app_id", "permission_name", name="uq_permission_app_key"),)


class RolePermission(Base):
    __tablename__ = "role_permissions"

    role_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("roles.role_id", ondelete="CASCADE"), primary_key=True
    )
    permission_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("permissions.permission_id", ondelete="CASCADE"), primary_key=True
    )

    role: Mapped["Role"] = relationship(back_populates="role_permissions")
    permission: Mapped["Permission"] = relationship(back_populates="role_permissions")

    __table_args__ = (Index("idx_role_permissions_role", "role_id"),)


class UserRole(Base):
    __tablename__ = "user_roles"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.user_id", ondelete="CASCADE"), primary_key=True
    )
    role_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("roles.role_id", ondelete="CASCADE"), primary_key=True
    )
    granted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    granted_by: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.user_id")
    )  # who assigned this role (audit trail)

    user: Mapped["User"] = relationship(back_populates="roles", foreign_keys=[user_id])
    role: Mapped["Role"] = relationship(back_populates="user_roles")
    granter: Mapped["User | None"] = relationship(foreign_keys=[granted_by])

    __table_args__ = (Index("idx_user_roles_user", "user_id"),)


class GroupRole(Base):
    __tablename__ = "group_roles"

    group_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("groups.group_id", ondelete="CASCADE"), primary_key=True
    )
    role_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("roles.role_id", ondelete="CASCADE"), primary_key=True
    )
    granted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    granted_by: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.user_id")
    )  # who assigned this role (audit trail)

    group: Mapped["Group"] = relationship(back_populates="group_roles")
    role: Mapped["Role"] = relationship(back_populates="group_roles")
    granter: Mapped["User | None"] = relationship(foreign_keys=[granted_by])

    __table_args__ = (Index("idx_group_roles_group", "group_id"),)

# ============================================================================
# 5b. SESSIONS  (SSO cookie -> DB-backed session, shared across every app
# that uses the authClient package)
# ============================================================================
# Cookie carries "<session_id>.<raw_secret_hex>". session_id is a plain UUID
# (safe to index/log); secret_hash is HMAC-SHA256(key=AUTH_SESSION_SECRET,
# object=raw_secret_hex) -- the raw secret itself is never stored.

class Session(Base):
    __tablename__ = "sessions"

    session_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False
    )
    secret_hash: Mapped[str] = mapped_column(Text, nullable=False)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    created_by_app: Mapped[str | None] = mapped_column(Text)
    user_agent: Mapped[str | None] = mapped_column(Text)
    ip_address: Mapped[str | None] = mapped_column(Text)

    user: Mapped["User"] = relationship(back_populates="sessions")

    __table_args__ = (
        Index("idx_sessions_user", "user_id"),
        Index("idx_sessions_expires", "expires_at"),
    )

# ============================================================================
# 6. (OPTIONAL) AUDIT LOG
# ============================================================================

class AuthAuditLog(Base):
    __tablename__ = "auth_audit_log"

    # NOTE: Integer, not BigInteger -- SQLite only treats a primary-key
    # column as an auto-incrementing rowid alias when its declared type is
    # the literal word "INTEGER"; BigInteger compiles to "BIGINT", which has
    # the same numeric affinity but does NOT qualify, so any INSERT that
    # omits log_id fails with "NOT NULL constraint failed". Confirmed by
    # testing directly against the original BigInteger-typed table.
    log_id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.user_id", ondelete="SET NULL")
    )
    app_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("apps.app_id", ondelete="SET NULL")
    )
    event_type: Mapped[str] = mapped_column(Text, nullable=False)  # 'login_success', 'login_failed', ...
    metadata_: Mapped[dict | None] = mapped_column("metadata", JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (Index("idx_audit_user", "user_id", "created_at"),)


# ============================================================================
# 7. AUTH SETTINGS  (DB-level feature toggles, e.g. audit logging -- shared
# by every app using authClient, flipped centrally instead of per-app config)
# ============================================================================

class AuthSetting(Base):
    __tablename__ = "auth_settings"

    setting_key: Mapped[str] = mapped_column(Text, primary_key=True)
    setting_value: Mapped[str | None] = mapped_column(Text)



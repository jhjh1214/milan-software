"""What crosses the wire. Pydantic, so a malformed push is rejected at the door.

Field names match the device's column names exactly (``*_tmm``, ``*_sen``), so
there is no translation layer to get wrong.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class QuoteLineIn(BaseModel):
    id: str = Field(min_length=36, max_length=36)
    sort_order: int
    room: str
    variant: str
    material_key: str | None = None
    layer: str
    parent_line_id: str | None = None
    #: Tenths of a millimetre. Never millimetres.
    width_tmm: int = Field(ge=0)
    height_tmm: int | None = Field(default=None, ge=0)
    raw_width: str
    raw_height: str
    quantity: int = Field(default=1, ge=1)
    #: What the device charged. Compared against the server's own figure, never
    #: trusted in place of it (§9.4).
    device_total_sen: int | None = None


class QuoteIn(BaseModel):
    id: str = Field(min_length=36, max_length=36)
    rate_card_version: int
    tier: str = "standard"
    language: str = "zh"
    customer_name: str | None = None
    customer_phone: str | None = None
    delivery_zone_id: str | None = None
    device_total_sen: int | None = None
    created_at: datetime
    updated_at: datetime
    device_id: str | None = None
    lines: list[QuoteLineIn] = []


class LineResult(BaseModel):
    line_id: str
    server_total_sen: int | None
    device_total_sen: int | None
    agreed: bool
    detail: str | None = None


class PushResult(BaseModel):
    quote_id: str
    #: True when this exact quote had already been accepted. A retry is a
    #: success, not an error: the device cannot know whether the first attempt
    #: landed before the signal dropped.
    duplicate: bool
    server_total_sen: int | None
    device_total_sen: int | None
    #: Non-empty means the two engines disagreed. The order is still accepted —
    #: §9.4 never loses a sale over a rounding dispute — and each disagreement
    #: is recorded for an admin to review.
    discrepancies: list[LineResult] = []


class LoginIn(BaseModel):
    """Phone plus PIN, not a name picked from a list.

    A roster on the sign-in screen would hand the staff list to anyone who
    opens the app, and the app is installed on handsets that travel to fairs.
    """

    phone: str = Field(min_length=3, max_length=40)
    pin: str = Field(min_length=1, max_length=12)
    #: The handset's own id, client-generated. Signing in again on the same one
    #: replaces its session rather than adding a second.
    device_id: str = Field(min_length=1, max_length=36)
    device_label: str | None = Field(default=None, max_length=80)


class UserOut(BaseModel):
    id: str
    name: str
    role: str
    language: str


class SessionOut(BaseModel):
    """Returned once, at sign-in. The token is not readable again afterwards —
    only its SHA-256 is stored."""

    token: str
    user: UserOut


class PublishIn(BaseModel):
    """An admin publishing a price list.

    The card arrives whole. A partial update would need a merge, and a merge of
    prices is a way to end up with a card nobody has ever read end to end.
    """

    list_id: str = Field(pattern="^(fair|standard)$")
    payload: dict


class PublishOut(BaseModel):
    version: int
    list_id: str
    published_by: str | None = None


class BundleOut(BaseModel):
    """The reference-data pull. §9.1: replace wholesale, never diff."""

    rate_card_version: int
    list_id: str
    #: Null when the device is already current, so a fair's connection is not
    #: spent re-downloading a card it already has.
    payload: dict | None = None
    up_to_date: bool

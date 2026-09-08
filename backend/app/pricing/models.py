"""Rate card data model. Mirrors `mobile/lib/pricing/models.dart`.

PURE. No FastAPI, no SQLAlchemy, no I/O. Loading the JSON is the caller's job;
this module only knows how to read a decoded dict.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from enum import Enum
from fractions import Fraction
from typing import Any

from ..core.length import Length
from ..core.money import Money
from .einvoice_threshold import ThresholdConfig


class PricingStage(Enum):
    """Which stage of the sale is being priced.

    The two round quantity by different rules and that is deliberate -- A10 and
    A11.
    """

    ESTIMATE = "estimate"
    FINAL = "final"


class Family(Enum):
    CURTAIN = "curtain"
    BLIND = "blind"
    TRACK = "track"
    FLOORING = "flooring"
    WALLPAPER = "wallpaper"
    ADDON = "addon"
    SERVICE = "service"


class DepositCategory(Enum):
    CURTAIN = "curtain"
    FLOORING = "flooring"
    WALLPAPER = "wallpaper"


class UnknownDepositCategory(Exception):
    """The line's deposit category cannot be decided.

    A hard failure rather than a default, because the default would be a guess
    about money: filing an unparented add-on under curtains could price it at a
    held curtain rate that its RM300 never bought.
    """


_DEPOSIT_CATEGORY_BY_FAMILY = {
    Family.CURTAIN: DepositCategory.CURTAIN,
    Family.BLIND: DepositCategory.CURTAIN,
    Family.TRACK: DepositCategory.CURTAIN,
    Family.FLOORING: DepositCategory.FLOORING,
    Family.WALLPAPER: DepositCategory.WALLPAPER,
}


def deposit_category_of(
    family: Family, *, parent_family: Family | None = None
) -> DepositCategory:
    """Maps a product family to the deposit category that covers it.

    **Kept in one function on purpose.** §6.1: silently applying a curtain lock
    to a flooring line is the expensive bug in this design.

    Add-ons and services take their **parent line's** category. A motor is
    charged on top of the blind it drives; it has no category of its own
    because it cannot exist on its own. A rule may also name its category
    outright -- self-levelling is family ``service`` and deposit category
    ``flooring`` -- and that answer wins, because a service belongs to the work
    it prepares.
    """
    if family in _DEPOSIT_CATEGORY_BY_FAMILY:
        return _DEPOSIT_CATEGORY_BY_FAMILY[family]

    if parent_family is None:
        raise UnknownDepositCategory(
            f"a {family.value} line has no parent and no deposit_category; "
            "it cannot be priced against a lock"
        )
    if parent_family not in _DEPOSIT_CATEGORY_BY_FAMILY:
        # One level only. An add-on hanging off an add-on is not a shape this
        # card produces, and allowing it would hide the same bug one level
        # deeper.
        raise UnknownDepositCategory(
            f"a {family.value} line hangs off another {parent_family.value} line"
        )
    return _DEPOSIT_CATEGORY_BY_FAMILY[parent_family]


class PriceBasis(Enum):
    PER_FT_WIDTH = ("per_ft_width", "ft")
    PER_SQFT = ("per_sqft", "sqft")
    PER_M_LENGTH = ("per_m_length", "m")
    PER_PIECE = ("per_piece", "pc")
    PER_SET = ("per_set", "set")
    PER_ROLL = ("per_roll", "roll")

    def __init__(self, wire: str, unit: str) -> None:
        self.wire = wire
        self.unit = unit

    @classmethod
    def from_wire(cls, value: str) -> PriceBasis:
        for member in cls:
            if member.wire == value:
                return member
        raise ValueError(f"unknown price basis: {value}")


class BandField(Enum):
    HEIGHT = "height"
    WIDTH = "width"
    NONE = "none"


class Layer(Enum):
    SINGLE = "single"
    DAY = "day"
    NIGHT = "night"


class Fulfilment(Enum):
    SUPPLY_INSTALL = "supply_install"
    SUPPLY_ONLY = "supply_only"


class CustomerTier(Enum):
    STANDARD = "standard"
    MVP = "mvp"


@dataclass(frozen=True)
class Localised:
    """A string in each supported language.

    A map rather than parallel fields, so a fourth language is a data change and
    not a migration in every table.
    """

    by_language: dict[str, str]

    def __call__(self, language: str) -> str:
        """Never returns None: a missing label must not blank out a product
        name in front of a customer."""
        return (
            self.by_language.get(language)
            or self.by_language.get("zh")
            or self.by_language.get("en")
            or next(iter(self.by_language.values()), "")
        )


@dataclass(frozen=True)
class PricingRule:
    id: str
    family: Family
    variant: str
    layer: Layer
    material_key: str | None
    fulfilment: Fulfilment
    labels: Localised
    basis: PriceBasis
    band_field: BandField
    #: Inclusive lower bound, tenths of a millimetre.
    band_min_tmm: int | None
    #: **Exclusive** upper bound. A 10ft cutoff is 30481, not 30480: exactly
    #: 10ft must fall in the lower band (A1).
    band_max_tmm: int | None
    band_labels: Localised | None
    rate_sen: int
    #: The flat MVP rate, if this product has one. Never a percentage.
    mvp_rate_sen: int | None
    #: Minimum **billed quantity**, applied before the rate multiplies.
    min_qty: Fraction | None
    sort_order: int
    coverage_sqft: Fraction | None = None
    bundle_qty: int = 1

    #: True when the rate on this row is a **placeholder**, not a real price.
    #:
    #: A row can exist before its price does -- stairs and landings were added
    #: as soon as the shape was known, with the rates still to come. The engine
    #: REFUSES to price a provisional row rather than quoting the placeholder,
    #: because a placeholder that reaches a customer is worse than a product
    #: that is not offered yet.
    provisional: bool = False
    deposit_category_override: DepositCategory | None = None
    is_addon: bool = False
    attaches_to: tuple[str, ...] | None = None

    #: This add-on is not a choice: the product cannot be installed without it.
    #:
    #: Client, Sep 2026 -- the stainless steel side guide is a **must** on an
    #: outdoor roller blind. It is still charged, so the wizard adds the line
    #: itself and tells the customer why rather than leaving RM400 to a tick
    #: box somebody forgets on the one product that cannot go up without it.
    #:
    #: Nothing here prices differently. A mandatory add-on is an ordinary line
    #: once it exists; this only decides who put it there.
    mandatory: bool = False
    note: str | None = None

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> PricingRule:
        raw_min = data.get("min_qty")
        if raw_min is not None and not isinstance(raw_min, int):
            # A fractional minimum would need exact handling; none exists on the
            # real price list, so reject rather than quietly accept a float.
            raise ValueError(f"min_qty must be an integer or null: {data['id']}")
        coverage = data.get("coverage_sqft")
        deposit = data.get("deposit_category")
        attaches = data.get("attaches_to")
        return cls(
            id=data["id"],
            family=Family(data["family"]),
            variant=data["variant"],
            layer=Layer(data["layer"]),
            material_key=data.get("material_key"),
            fulfilment=Fulfilment(data["fulfilment"]),
            labels=Localised(dict(data["labels"])),
            basis=PriceBasis.from_wire(data["basis"]),
            band_field=BandField(data["band_field"]),
            band_min_tmm=data.get("band_min_tmm"),
            band_max_tmm=data.get("band_max_tmm"),
            band_labels=(
                Localised(dict(data["band_labels"]))
                if data.get("band_labels")
                else None
            ),
            rate_sen=data["rate_sen"],
            mvp_rate_sen=data.get("mvp_rate_sen"),
            min_qty=None if raw_min is None else Fraction(raw_min),
            sort_order=data["sort_order"],
            coverage_sqft=None if coverage is None else Fraction(coverage),
            bundle_qty=data.get("bundle_qty", 1),
            provisional=data.get("provisional", False),
            deposit_category_override=(DepositCategory(deposit) if deposit else None),
            is_addon=data.get("is_addon", False),
            attaches_to=tuple(attaches) if attaches else None,
            mandatory=data.get("mandatory", False),
            note=data.get("note"),
        )

    @property
    def deposit_category(self) -> DepositCategory:
        return self.deposit_category_override or deposit_category_of(self.family)

    def band_contains(self, value: Length) -> bool:
        """Lower bound inclusive, upper bound exclusive.

        The fencepost that decides whether exactly 10ft costs RM46 or RM58.
        """
        # Written out rather than collapsed into one negated expression: this
        # is the RM144 fencepost, it mirrors the Dart line for line, and the
        # two bounds are deliberately asymmetric. Clarity wins over brevity.
        if self.band_field is BandField.NONE:
            return True
        if self.band_min_tmm is not None and value.tmm < self.band_min_tmm:
            return False
        if self.band_max_tmm is not None and value.tmm >= self.band_max_tmm:  # noqa: SIM103
            return False
        return True

    def rate_for_tier(self, tier: CustomerTier) -> int:
        """MVP is a flat substitute, not a discount sum."""
        if tier is CustomerTier.MVP and self.mvp_rate_sen is not None:
            return self.mvp_rate_sen
        return self.rate_sen


@dataclass(frozen=True)
class DeliveryZone:
    id: str
    charge_sen: int
    charge_kind: str
    area_labels: tuple[str, ...]
    labels: Localised

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> DeliveryZone:
        return cls(
            id=data["id"],
            charge_sen=data["charge_sen"],
            charge_kind=data["charge_kind"],
            area_labels=tuple(data["area_labels"]),
            labels=Localised(dict(data["labels"])),
        )


@dataclass(frozen=True)
class ProductRule:
    """A constraint rather than a price."""

    id: str
    variant: str
    kind: str
    messages: Localised
    target: str | None = None
    dimension: str | None = None
    value_tmm: int | None = None

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> ProductRule:
        return cls(
            id=data["id"],
            variant=data["variant"],
            kind=data["kind"],
            messages=Localised(dict(data["messages"])),
            target=data.get("target"),
            dimension=data.get("dimension"),
            value_tmm=data.get("value_tmm"),
        )


@dataclass(frozen=True)
class RateCardConfig:
    min_deposit_sen: int
    band_edge_warn_tmm: int
    default_unit_width: str = "ft"
    default_unit_height: str = "ft"

    #: At or over this, buyer details are legally required. RM10,000, since
    #: 1 January 2026. SPEC.md §10.2 -- Malaysian law, not this shop's policy.
    einvoice_threshold_sen: int = 1_000_000

    #: At or over this, the quote wizard asks. RM8,000, and only on an
    #: estimate: §10.4's timing trap is that an order quoted at RM8,500 settles
    #: at RM11,200, and by then the customer has gone home.
    einvoice_prompt_sen: int = 800_000

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> RateCardConfig:
        return cls(
            min_deposit_sen=data["min_deposit_sen"],
            band_edge_warn_tmm=data["band_edge_warn_tmm"],
            default_unit_width=data.get("default_unit_width", "ft"),
            default_unit_height=data.get("default_unit_height", "ft"),
            # Defaulted rather than required, so a card published before this
            # still loads -- and defaults to the law rather than to no check at
            # all. A missing threshold that meant "never ask" would be silent
            # non-compliance on exactly the oldest data.
            einvoice_threshold_sen=data.get("einvoice_threshold_sen", 1_000_000),
            einvoice_prompt_sen=data.get("einvoice_prompt_sen", 800_000),
        )

    @property
    def thresholds(self) -> ThresholdConfig:
        """The two figures as the threshold rule wants them."""
        return ThresholdConfig(
            threshold=Money(self.einvoice_threshold_sen),
            prompt=Money(self.einvoice_prompt_sen),
        )


@dataclass(frozen=True)
class CardPromo:
    code: str
    valid_from: date
    valid_to: date
    note: str | None = None

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> CardPromo:
        return cls(
            code=data["code"],
            valid_from=date.fromisoformat(data["valid_from"]),
            valid_to=date.fromisoformat(data["valid_to"]),
            note=data.get("note"),
        )

    def covers(self, day: date) -> bool:
        """Inclusive of the final day: a quote at 9pm on closing night counts."""
        return self.valid_from <= day <= self.valid_to


@dataclass(frozen=True)
class RateCard:
    version: int
    provisional: bool
    config: RateCardConfig
    rules: tuple[PricingRule, ...]
    delivery_zones: tuple[DeliveryZone, ...] = ()
    product_rules: tuple[ProductRule, ...] = ()
    promo: CardPromo | None = None
    _by_id: dict[str, PricingRule] = field(default_factory=dict, repr=False)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> RateCard:
        rules = tuple(PricingRule.from_json(r) for r in data["rules"])
        return cls(
            version=data["version"],
            provisional=data.get("provisional", False),
            config=RateCardConfig.from_json(data["config"]),
            rules=rules,
            delivery_zones=tuple(
                DeliveryZone.from_json(z) for z in data.get("delivery_zones", [])
            ),
            product_rules=tuple(
                ProductRule.from_json(p) for p in data.get("product_rules", [])
            ),
            promo=(CardPromo.from_json(data["promo"]) if data.get("promo") else None),
            _by_id={r.id: r for r in rules},
        )

    def rule(self, rule_id: str) -> PricingRule:
        return self._by_id[rule_id]

    def is_expired_on(self, day: date) -> bool:
        """True when these rates are promotional and the promotion has ended."""
        return self.promo is not None and not self.promo.covers(day)

    def materials_for(self, variant: str) -> list[str]:
        return sorted(
            {
                r.material_key
                for r in self.rules
                if r.variant == variant and r.material_key
            }
        )

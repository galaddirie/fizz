import type { Component } from 'vue';
import {
  CursorArrowRaysIcon,
  BoltIcon,
  ClockIcon,
  GlobeAltIcon,
  EnvelopeIcon,
  CircleStackIcon,
  CodeBracketIcon,
  ArrowPathIcon,
  VariableIcon,
  FunnelIcon,
  AdjustmentsHorizontalIcon,
  ArrowsPointingOutIcon,
  ArrowsPointingInIcon,
  ArrowsRightLeftIcon,
  ListBulletIcon,
  BugAntIcon,
  CalculatorIcon,
  DocumentTextIcon,
  ArrowDownTrayIcon,
  ChatBubbleLeftRightIcon,
} from '@heroicons/vue/24/outline';

export const stepIconMap: Record<string, Component> = {
  'hero-cursor-arrow-rays': CursorArrowRaysIcon,
  'hero-bolt': BoltIcon,
  'hero-clock': ClockIcon,
  'hero-globe-alt': GlobeAltIcon,
  'hero-envelope': EnvelopeIcon,
  'hero-circle-stack': CircleStackIcon,
  'hero-code-bracket': CodeBracketIcon,
  'hero-arrow-path': ArrowPathIcon,
  'hero-variable': VariableIcon,
  'hero-funnel': FunnelIcon,
  'hero-adjustments-horizontal': AdjustmentsHorizontalIcon,
  'hero-arrows-pointing-out': ArrowsPointingOutIcon,
  'hero-arrows-pointing-in': ArrowsPointingInIcon,
  'hero-arrows-right-left': ArrowsRightLeftIcon,
  'hero-list-bullet': ListBulletIcon,
  'hero-bug-ant': BugAntIcon,
  'hero-calculator': CalculatorIcon,
  'hero-document-text': DocumentTextIcon,
  'hero-arrow-down-tray': ArrowDownTrayIcon,
  'hero-chat-bubble-left-right': ChatBubbleLeftRightIcon,
};

export const fallbackIcon = CodeBracketIcon;

export const getStepIcon = (iconName?: string): Component =>
  iconName ? stepIconMap[iconName] || fallbackIcon : fallbackIcon;

export const isImageIcon = (iconName?: string): boolean =>
  !!iconName && (iconName.startsWith('/') || /\.(svg|png|jpe?g|webp)$/i.test(iconName));

import { ReactNode } from "react";

interface Step {
  icon: ReactNode;
  title: string;
  description: string;
  badgeColor?: string; // tailwind bg-color, default blue
}

interface Props {
  title: string;
  steps: Step[];
  className?: string;
}

const HowItWorks: React.FC<Props> = ({ title, steps, className }) => {
  return (
    <div className={`bg-base-300 rounded-lg p-6 ${className ?? ""}`.trim()}>
      <h2 className="text-xl font-semibold mb-4 text-center">{title}</h2>
      <div className="space-y-4">
        {steps.map((step, idx) => (
          <div className="flex items-start space-x-3" key={idx}>
            <div
              className={`${step.badgeColor ?? "bg-blue-500"} text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5`}
            >
              {idx + 1}
            </div>
            <div>
              <h3 className="font-medium">{step.title}</h3>
              <p className="text-gray-600">{step.description}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default HowItWorks; 